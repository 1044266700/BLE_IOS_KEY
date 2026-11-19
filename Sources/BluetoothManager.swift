import Foundation
import CoreBluetooth
import CommonCrypto
import Combine
import Security
import UIKit

class BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - 公开状态
    @Published var statusText: String = "未连接"
    @Published var isConnected: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var isScanning: Bool = false
    @Published private(set) var  autoConnectEnabled: Bool = true
    @Published private(set) var  backgroundBluetoothEnabled: Bool = false
    @Published private(set) var  timingLogs: [String] = []
    @Published var filteredRSSI: Int?
    @Published var batteryLevel: Int?
    @Published var isUnlocked: Bool = false
    @Published var isNearStable: Bool = false
    @Published var isCalibrating: Bool = false
    @Published private(set) var  isCalibrationBusy: Bool = false
    @Published private(set) var  calibrationResultText: String?
    @Published private(set) var  calibrationSucceeded: Bool = false
    @Published private(set) var isWaitingForProximity: Bool = false
    
    private enum AuthenticationState{
        case idle
        case waitingForResponseNotification
        case waitingForChallengeWrite
        case waitingForModuleResponse
        case waitingForProofWrite
        case waitingForAuthenticationStatus
        case authenticated
    }
    
    private enum SetupStage {
        case idle
        case discoveringServices
        case discoveringCharacteristics
        case authenticating
        case ready
    }
    
    private enum KeyCommand: UInt8{
        case unlock = 0xA1
        case lock = 0xA2
        case calibrateOneMeter = 0xB1

        var title: String {
            switch self {
                case .unlock: return "解锁"
                case .lock: return "闭锁"
                case .calibrateOneMeter: return "一米标定"
            }
        }
    }

    private enum CommandResultCode: UInt8 {
        case success = 0
        case rejected = 1
        case busy = 2
        case notNear = 3
        case invalidRSSI = 4
        case insufficientSamples = 5
        case storageError = 6
        case started = 7
        case unsupported = 8
        case replayed = 9
        case sessionRejected = 10
    }

    private struct CommandResult {
        let command: UInt8
        let sequence: UInt32
        let code: CommandResultCode?
        let rawCode: UInt8
        let status: UInt8
    }  
    
    // MARK: - 私有属性
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    
    private var challengeCharacteristic: CBCharacteristic?   
    private var responseCharacteristic: CBCharacteristic?    
    private var commandCharacteristic: CBCharacteristic?   
    private var rssiCharacteristic: CBCharacteristic?    
    private var statusCharacteristic: CBCharacteristic?    
    private var batteryCharacteristic: CBCharacteristic?    

    private let deviceName = "BLE_KEY"
    private let centralRestoreIdentifier = "com.example.MyFirstiOSApp.BLEKeyCentral"
    
    private let serviceUUID         = CBUUID(string: "00000001-12BC-4A5E-9C01-23456789ABCD")
    private let challengeUUID       = CBUUID(string: "00000002-12BC-4A5E-9C01-23456789ABCD")
    private let responseUUID        = CBUUID(string: "00000003-12BC-4A5E-9C01-23456789ABCD")
    private let commandUUID         = CBUUID(string: "00000004-12BC-4A5E-9C01-23456789ABCD")
    private let rssiUUID            = CBUUID(string: "00000005-12BC-4A5E-9C01-23456789ABCD")
    private let statusUUID          = CBUUID(string: "00000006-12BC-4A5E-9C01-23456789ABCD")
    private let commandResultMessageType: UInt8 = 0x01
    private let commandResultLength = 8
    private let batteryServiceUUID  = CBUUID(string: "180F")
    private let batteryLevelUUID    = CBUUID(string: "2A19")
    // =====================================================
    
    //蓝牙设备号唯一
    private let aesKey: [UInt8] = [
        0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
        0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F,0x3C
    ]
    private var authState: AuthenticationState = .idle
    private var setupStage: SetupStage = .idle
    private var confirmedNotificationUUIDs = Set<CBUUID>()
    private var phoneNonce: Data?
    private var pendingModuleResponse: Data?
    private var pendingAuthenticationStatus = false
    private var commandSessionTag: Data?
    private var connectionID: UInt = 0

    private var commandSequence: UInt32 = 0
    private var pendingCommand: KeyCommand?
    private var pendingCommandSequence: UInt32?
    private var pendingCommandWriteConfirmed = false
    private var pendingCommandResult: CommandResult?
    private var activeCalibrationSequence: UInt32?
    
    private let pairedPeripheralIdentifierKey = "AstraKey.pairedPeripheralIdentifier"
    private var pairedPeripheralIdentifier: UUID? {
        get {
            guard let value = UserDefaults.standard.string(forKey:pairedPeripheralIdentifierKey) else {
                return nil
            }
            return UUID(uuidString: value)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey:pairedPeripheralIdentifierKey) 
        }
    }
    private var connectionFlowStartedAt = CFAbsoluteTimeGetCurrent()
    
    private var connectionTimeout: DispatchWorkItem?
    private var phaseTimeout: DispatchWorkItem?
    private var responseReadFallback: DispatchWorkItem?
    private var commandTimeout: DispatchWorkItem?
    private var calibrationResultTimeout: DispatchWorkItem?
    private var optionalUpdatesWorkItem: DispatchWorkItem?
    private var optionalUpdatesStarted = false

    // 直连挂起期间的并行扫描回退，用于发现更换后的新模块。
    private let directReconnectFallbackScanDelay: TimeInterval = 4
    private var directFallbackScanWorkItem: DispatchWorkItem?
    private var isFallbackScanActive = false
    private var ignoredPeripheralIdentifiers = Set<UUID>()
    
    // 断开后的自动重连与失败退避。
    private var reconnectWorkItem: DispatchWorkItem?
    private var consecutiveConnectionFailures = 0
    
    // willRestoreState 早于 poweredOn，先保存外设，等蓝牙可用后再处理。
    private var restoredPeripheral: CBPeripheral?
    
    // 认证后模块仍需积累 RSSI 样本，解锁先等待近区稳定，超时后照常发送。
    private let unlockProximityWaitTimeout: TimeInterval = 1.5
    private var pendingUnlockWorkItem: DispatchWorkItem?
    
    override init() {
        super.init()
        
        var options: [String: Any] = [:]
        let backgroundModes = Bundle.main.object(
            forInfoDictionaryKey: "UIBackgroundModes"
        ) as? [String] ?? []

        if backgroundModes.contains("bluetooth-central") {
            backgroundBluetoothEnabled = true
            options[CBCentralManagerOptionRestoreIdentifierKey] = centralRestoreIdentifier
        } else {
            // 未声明后台模式时启用状态恢复会让 CoreBluetooth 在启动时异常终止。
            print("[BLE_KEY] 安装包未声明 bluetooth-central，已禁用 Central 状态恢复")
        }
        
        centralManager = CBCentralManager(
            delegate: self, 
            queue: nil,
            options: options.isEmpty ? nil : options
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    // MARK: - 对外方法
    func startScan(allowDirectReconnect: Bool = true) {
        autoConnectEnabled = true
        guard centralManager.state == .poweredOn else {
            statusText = "请打开蓝牙"
            return
        }
        if let peripheral = connectedPeripheral,
            peripheral.state == .connected || peripheral.state == .connecting{
                statusText = peripheral.state == .connected ? "设备已连接" : "正在连接设备..."
                return
            }
        centralManager.stopScan()
        clearConnectionState()
        resetConnectionTiming()
        restoredPeripheral = nil
        
        //固定模块优先UUID 直连, ；等待进入范围时不主动取消，也可手动重新扫描。
        let shouldAttemptDirect = allowDirectReconnect && pairedPeripheralIdentifier != nil
        appendTimingLog(shouldAttemptDirect ? "连接路径：UUID 直接重连｜0 ms" : "连接路径：服务 UUID 扫描｜0 ms")
        if shouldAttemptDirect && attemptDirectReconnect() {
            return
        }
        if shouldAttemptDirect {
            logConnectionTiming("直连不可用，回退服务扫描")
        }
        
        isScanning = true
        statusText = "正在自动搜索 BLE_KEY..."
        debugLog("按车钥匙服务 UUID 启动扫描，允许后台自动连接")

        
        // iOS 后台扫描必须指定服务 UUID，不能使用 withServices: nil。
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

private func attemptDirectReconnect() -> Bool {
    guard let identifier = pairedPeripheralIdentifier else { return false }

    if let peripheral = centralManager.retrieveConnectedPeripherals(
        withServices: [serviceUUID]
    ).first(where: {$0.identifier == identifier}) {
        debugLog("找到系统已连接的固定模块：\(identifier.uuidString)")
        if peripheral.state == .connected {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            isScanning = false
            beginServiceDiscovery(for: peripheral)
        } else {
            connect(to: peripheral, directReconnect: true)
        }
        return true
    }
    guard let peripheral = centralManager.retrievePeripherals(
        withIdentifiers: [identifier]
    ).first else {
        debugLog("系统中没有已保存的模块记录，进入普通扫描")
        return false
    }

    connect(to: peripheral, directReconnect: true)
    return true
}
    
    func disconnect() {
        //手动断开后暂停自动重连；再次点击扫描按钮可重新开启。
        autoConnectEnabled = false
        failConnection ("已断开, 自动连接已暂停")
    }

    func rescan() {
        autoConnectEnabled = true
        let pendingPeripheral = connectedPeripheral
        centralManager.stopScan()
        clearConnectionState()
        consecutiveConnectionFailures = 0
        ignoredPeripheralIdentifiers.removeAll()
        if let pendingPeripheral = pendingPeripheral {
            centralManager.cancelPeripheralConnection(pendingPeripheral)
        }
        startScan(allowDirectReconnect: false)
    }
    
    func unlock() {
        guard !isWaitingForProximity else { return }
        // 刚认证完成时模块还在积累 RSSI 样本，先等待近区稳定，避免必然被拒。
        guard setupStage == .ready,
              isAuthenticated,
              !isNearStable,
              pendingCommand == nil,
              !isCalibrationBusy else {
            sendCommand(.unlock)
            return
        }
        isWaitingForProximity = true
        statusText = "正在确认距离..."
        let session = connectionID
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.connectionID == session,
                  self.isWaitingForProximity else { return }
            self.debugLog("等待近区稳定超时，照常发送解锁指令")
            self.finishUnlockWait(send: true)
        }
        pendingUnlockWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + unlockProximityWaitTimeout, execute: work)
    }
    func lock() {
        finishUnlockWait(send: false)
        sendCommand(.lock)
    }
    func calibrateAtOneMeter() {
        finishUnlockWait(send: false)
        sendCommand(.calibrateOneMeter)
    }

    private func finishUnlockWait(send: Bool) {
        guard isWaitingForProximity else { return }
        pendingUnlockWorkItem?.cancel()
        pendingUnlockWorkItem = nil
        isWaitingForProximity = false
        if send {
            sendCommand(.unlock)
        }
    }
    
    private func connect(to peripheral: CBPeripheral, directReconnect: Bool = false) {
        centralManager.stopScan()
        clearConnectionState()
        
        connectedPeripheral = peripheral
        peripheral.delegate = self
        statusText = directReconnect ? "等待固定模块进入范围..." : "正在连接 \(deviceName)..."
        debugLog("\(directReconnect ? "直接重连" : "开始连接") \(peripheral.identifier.uuidString)")
        centralManager.connect(peripheral, options: nil)
        if directReconnect {
            scheduleDirectFallbackScan(for: peripheral)
        } else {
            scheduleConnectionTimeout(for: peripheral)
        }
    }

    /// 直连挂起不会超时；前台等待数秒后并行扫描服务，发现其他模块（如更换模块）时再切换。
    private func scheduleDirectFallbackScan(for peripheral: CBPeripheral) {
        directFallbackScanWorkItem?.cancel()
        let session = connectionID
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self,
                  let peripheral = peripheral,
                  self.connectionID == session else { return }
            self.directFallbackScanWorkItem = nil
            self.startDirectFallbackScan(for: peripheral)
        }
        directFallbackScanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + directReconnectFallbackScanDelay, execute: work)
    }

    private func startDirectFallbackScan(for peripheral: CBPeripheral) {
        guard autoConnectEnabled,
              !isFallbackScanActive,
              centralManager.state == .poweredOn,
              connectedPeripheral === peripheral,
              peripheral.state == .connecting,
              peripheral.identifier == pairedPeripheralIdentifier,
              UIApplication.shared.applicationState == .active else { return }
        isFallbackScanActive = true
        debugLog("直连等待中，前台并行扫描车钥匙服务")
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func stopDirectFallbackScan() {
        directFallbackScanWorkItem?.cancel()
        directFallbackScanWorkItem = nil
        if isFallbackScanActive {
            centralManager.stopScan()
            isFallbackScanActive = false
        }
    }

    @objc private func applicationDidBecomeActive() {
        // 等待期在后台结束时，回到前台补上并行扫描；等待期未结束则交给定任务。
        guard directFallbackScanWorkItem == nil,
              let peripheral = connectedPeripheral,
              peripheral.state == .connecting else { return }
        startDirectFallbackScan(for: peripheral)
    }

    private func scheduleConnectionTimeout(for peripheral: CBPeripheral) {
        connectionTimeout?.cancel()
        let session = connectionID
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self,
            let peripheral = peripheral,
            self.connectionID == session,
            self.connectedPeripheral === peripheral,
            peripheral.state == .connecting else { return }
            self.failConnection("连接超时，将继续自动搜索")
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func beginServiceDiscovery(for peripheral: CBPeripheral) {
        guard connectedPeripheral === peripheral else { return }
        stopDirectFallbackScan()
        connectionTimeout?.cancel()
        connectionTimeout = nil
        isConnected = true
        isScanning = false
        setupStage = .discoveringServices
        statusText = "已连接, 正在发现车钥匙服务..."
        debugLog("BLE 已连接，优先发现车钥匙服务")
        schedulePhaseTimeout(message: "服务发现超时", peripheral: peripheral)
        peripheral.discoverServices([serviceUUID])
    }

    /// - Parameter linkLost: 链路层断开/连接失败；已认证会话的链路断开会立即重新挂起直连。
    private func failConnection(_ message: String, linkLost: Bool = false) {
        let peripheral = connectedPeripheral
        let wasAuthenticated = authState == .authenticated
        // 主动取消仍会收到 didDisconnect，需等回调结束后再重连，否则会被误判为新连接断开。
        let needsCancel = peripheral.map { $0.state != .disconnected } ?? false
        debugLog(message)
        centralManager.stopScan()
        clearConnectionState()
        if needsCancel, let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        statusText = message

        // 并行扫描切换到的新模块未通过认证时，本次运行内不再尝试它，回到已配对模块。
        if let peripheral = peripheral,
           let paired = pairedPeripheralIdentifier,
           peripheral.identifier != paired,
           !wasAuthenticated {
            ignoredPeripheralIdentifiers.insert(peripheral.identifier)
        }

        guard autoConnectEnabled else { return }

        if wasAuthenticated && linkLost {
            // 正常使用中离开范围；立即重新挂起 UUID 直连，靠近即连。
            consecutiveConnectionFailures = 0
        } else {
            consecutiveConnectionFailures += 1
        }
        // 前两次失败立即重试；持续失败（如密钥不匹配被模块断开）再指数退避。
        // 上限 8 秒，保证后台被唤醒的执行窗口内仍能重新发起连接。
        let backoff: TimeInterval = consecutiveConnectionFailures <= 2
            ? 0
            : min(pow(2, Double(consecutiveConnectionFailures - 2)), 8)
        scheduleReconnect(after: max(backoff, needsCancel ? 1 : 0), message: message)
    }

    private func scheduleReconnect(after delay: TimeInterval, message: String) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        guard delay > 0 else {
            startScan()
            if connectedPeripheral != nil || isScanning {
                statusText = "\(message), 等待自动重连"
            }
            return
        }

        statusText = "\(message), \(Int(delay)) 秒后重连"
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.autoConnectEnabled,
                  self.connectedPeripheral == nil,
                  !self.isScanning else { return }
            self.reconnectWorkItem = nil
            self.startScan()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearConnectionState() {
        connectionID &+= 1
        stopDirectFallbackScan()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        pendingUnlockWorkItem?.cancel()
        pendingUnlockWorkItem = nil
        isWaitingForProximity = false
        connectionTimeout?.cancel()
        phaseTimeout?.cancel()
        responseReadFallback?.cancel() 
        calibrationResultTimeout?.cancel() 
        optionalUpdatesWorkItem?.cancel() 
        connectionTimeout = nil 
        phaseTimeout = nil 
        responseReadFallback = nil 
        calibrationResultTimeout = nil 
        optionalUpdatesWorkItem = nil 
        optionalUpdatesStarted = false 
        resetPendingCommand() 
        
        isConnected = false 
        isScanning = false 
        isAuthenticated = false 
        filteredRSSI = nil 
        batteryLevel = nil 
        isUnlocked = false 
        isNearStable = false 
        isCalibrating = false 
        isCalibrationBusy = false 
        calibrationResultText = nil 
        calibrationSucceeded = false 
        
        authState = .idle 
        setupStage = .idle 
        confirmedNotificationUUIDs.removeAll() 
        phoneNonce = nil 
        pendingModuleResponse = nil 
        pendingAuthenticationStatus = false 
        commandSessionTag = nil 
        commandSequence = 0 
        
        activeCalibrationSequence = nil 
        
        challengeCharacteristic = nil
        responseCharacteristic = nil
        commandCharacteristic = nil
        rssiCharacteristic = nil
        statusCharacteristic = nil
        batteryCharacteristic = nil
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
    }

    private func resetPendingCommand() {
        commandTimeout?.cancel()
        responseReadFallback?.cancel()
        commandTimeout = nil
        responseReadFallback = nil
        pendingCommand = nil
        pendingCommandSequence = nil
        pendingCommandWriteConfirmed = false
        pendingCommandResult = nil
    }

    private func debugLog(_ message: String){
        print("[BLE_KEY] \(message)")
    }

    private func resetConnectionTiming(){
        connectionFlowStartedAt = CFAbsoluteTimeGetCurrent()
        appendTimingLog("开始连接流程｜0 ms")
    }

    private func logConnectionTiming(_ stage: String){
        let milliseconds = (CFAbsoluteTimeGetCurrent() - connectionFlowStartedAt) * 1000
        appendTimingLog("\(stage) ｜\(Int(milliseconds.rounded())) ms")
    }

    private func appendTimingLog(_ message: String) {
        timingLogs.append(message)
        if timingLogs.count > 100 {
            timingLogs.removeFirst(timingLogs.count - 100)
        }
        debugLog("阶段耗时｜\(message)")
    }

    func clearTimingLogs() {
        timingLogs.removeAll()
    }

    private func schedulePhaseTimeout(after seconds: TimeInterval = 10,
                                     message: String,
                                     peripheral: CBPeripheral){
        phaseTimeout?.cancel()
        let session = connectionID
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self,
                  let peripheral = peripheral,
                  self.connectionID == session,
                  self.connectedPeripheral === peripheral,
                  self.isConnected else { return }
            self.failConnection(message)
        }
         phaseTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }
    // MARK: - 双向认证
    private func prepareAuthentication() {
        guard setupStage == .discoveringCharacteristics,
              let challenge = challengeCharacteristic,
              let response = responseCharacteristic,
              let command = commandCharacteristic,
              let status = statusCharacteristic, 
              challenge.properties.contains(.write),
              response.properties.contains(.read),
              response.properties.contains(.notify),
              command.properties.contains(.write),
              status.properties.contains(.read),
              status.properties.contains(.notify) else {
            authenticationFailed("模块特征不完整或读写属性不匹配")
            return
        }
        
        setupStage = .authenticating
        authState = .waitingForResponseNotification
        isAuthenticated = false
        confirmedNotificationUUIDs.removeAll()

        // Challenge 先入队，避免两个 CCCD 写操作阻塞认证；通知订阅随后并行完成。
        startAuthentication()
        beginNotificationSubscriptions()
    }
    private func beginNotificationSubscriptions() {
        guard let peripheral = connectedPeripheral,
              let response = responseCharacteristic,
              let status = statusCharacteristic,
              setupStage == .authenticating else { return }

        //两个 CCC 订阅并行发起，不阻断已经开始的AES认证。
        for characteristic in [response, status] {
            debugLog("订阅 \(characteristic.uuid.uuidString)")
            if characteristic.isNotifying {
                confirmedNotificationUUIDs.insert(characteristic.uuid)
            } else {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    private func notificationSubscriptionCompleted(_ characteristic: CBCharacteristic,
                                                  for peripheral: CBPeripheral){
        guard connectedPeripheral === peripheral,
              setupStage == .subscribingNotifications,
              characteristic.uuid == responseUUID || characteristic.uuid == statusUUID,
              characteristic.isNotifying else { return }
        debugLog("已订阅 \(characteristic.uuid.uuidString)")
        confirmedNotificationUUIDs.insert(characteristic.uuid)
    }

//TODO
    private func startAuthentication() {
        guard let peripheral = connectedPeripheral,
              let characteristic = challengeCharacteristic,
              setupStage == .authenticating,
              authState == .waitingForResponseNotification,
              let nonce = randomBytes(count: 16) else {
            if authState != .authenticated {
                authenticationFailed("无法开始认证")
            }
            return
        }

        phoneNonce = Data(nonce)
        pendingModuleResponse = nil
        pendingAuthenticationStatus = false
        commandSessionTag = nil
        authState = .waitingForChallengeWrite
        isAuthenticated = false
        statusText = "正在优先发送Challenge..."
        debugLog("发送16字节Challenge，通知订阅并行进行")
        logConnectionTiming("开始认证，Challenge 优先提交")
        schedulePhaseTimeout(after:8,
                    message: "认证超时：challenge写入未确认",
                    peripheral: peripheral)
        // 第一步必须写原始 phone_nonce，由模块计算 AES(phone_nonce)。
        peripheral.writeValue(Data(nonce), for: characteristic, type: .withResponse)
    }

    private func handleModuleResponse(_ data: Data){
        guard setupStage == .authenticating else { return }
        if authState == .waitingForChallengeWrite {
            // 通知可能先于 Challenge 写确认到达，先缓存，确认写成功后再发送 Proof。
            pendingModuleResponse = data
            debugLog("认证响应早于 Challenge 写确认到达，已缓存")
            return
        }
        guard authState == .waitingForModuleResponse else { return }
        pendingModuleResponse = nil
        guard data.count == 32 else{
            authenticationFailed("认证响应长度错误 ： \(data.count)字节")
            return
        }
        guard let expectedNonce = phoneNonce,
            let decrypted = aesECBDecrypt(data: Data(data.prefix(16))),
            decrypted == expectedNonce else{
            authenticationFailed("模块认证失败：随机数不匹配")
            return
        }
        guard let proof = aesECBEncrypt(data: Data(data.suffix(16))),
              let peripheral = connectedPeripheral,          // 正确解包
              let challenge = challengeCharacteristic else {
            authenticationFailed("生成手机认证应答失败")
            return
        }
        responseReadFallback?.cancel()
        responseReadFallback = nil
        phoneNonce = nil
        // 命令明文绑定本次模块随机数，防止旧会话密文跨会话重放。
        commandSessionTag = Data(data.suffix(16).prefix(4))
        authState = .waitingForProofWrite
        statusText = "模块已验证，正在验证手机..."
        debugLog("模块响应校验通过，发送proof")
        schedulePhaseTimeout(after:8,
                    message: "认证超时：proof写入未确认",
                    peripheral: peripheral)

        // 第二步返回 AES(module_nonce)，此时还不能宣告双向认证成功。
        peripheral.writeValue(proof, for: challenge, type: .withResponse)
    }

    private func completeAuthentication() {
        guard authState == .waitingForAuthenticationStatus,
              let peripheral = connectedPeripheral else { return }
        phaseTimeout?.cancel()
        responseReadFallback?.cancel()
        phaseTimeout = nil
        responseReadFallback = nil
        phoneNonce = nil
        pendingModuleResponse = nil
        pendingAuthenticationStatus = false
        commandSequence = 0
        setupStage = .ready
        authState = .authenticated
        isAuthenticated = true
        consecutiveConnectionFailures = 0
        if pairedPeripheralIdentifier != peripheral.identifier {
            ignoredPeripheralIdentifiers.removeAll()
        }
        pairedPeripheralIdentifier = peripheral.identifier
        statusText = "双向认证完成"
        debugLog("双向认证完成，已保存固定模块 UUID")
        logConnectionTiming("双向认证完成，可以发送指令")
        scheduleOptionalUpdates(after: 2)
    }

    private func scheduleOptionalUpdates(after seconds: TimeInterval) {
        guard setupStage == .ready, !optionalUpdatesStarted else { return }
        optionalUpdatesWorkItem?.cancel()
        let session = connectionID
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.connectionID == session,
                  self.setupStage == .ready else { return }
            self.beginOptionalUpdates()
        }
        optionalUpdatesWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func beginOptionalUpdates() {
        guard setupStage == .ready,
              !optionalUpdatesStarted,
              let peripheral = connectedPeripheral else { return }
        optionalUpdatesStarted = true
        optionalUpdatesWorkItem?.cancel()
        optionalUpdatesWorkItem = nil
        // RSSI 和电量在认证及首条指令之外处理，失败不影响钥匙指令。
        if let rssi = rssiCharacteristic {
            if rssi.properties.contains(.read) {
                peripheral.readValue(for: rssi)
            }
        if rssi.properties.contains(.notify), !rssi.isNotifying {
            peripheral.setNotifyValue(true, for: rssi)
        }
    }

    if let batteryService = peripheral.services?.first(where: {
        $0.uuid == batteryServiceUUID
    }) {
        peripheral.discoverCharacteristics([batteryLevelUUID], for: batteryService)
    } else {
        peripheral.discoverServices([batteryServiceUUID])
    }
}

    private func authenticationFailed(_ message: String){
        // 认证失败后模块可能还在等待proof
        failConnection(message)
    }

    private func scheduleResponseReadFallback(){
        responseReadFallback?.cancel()
        let session = connectionID
        let read = DispatchWorkItem { [weak self] in
            guard let self = self,
                self.connectionID == session,
                self.authState == .waitingForModuleResponse,
                let peripheral = self.connectedPeripheral,
                let response = self.responseCharacteristic else { return }
                self.debugLog("认证响应通知未到达，回退读取 Response")
                peripheral.readValue(for:response)                     
            }
        responseReadFallback  = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: read)
    }
    private func scheduleCommandTimeout(for sequence: UInt32, peripheral: CBPeripheral) {
        commandTimeout?.cancel()
        let session = connectionID
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self,
            let peripheral = peripheral,
            self.connectionID == session,
            self.connectedPeripheral === peripheral,
            self.pendingCommandSequence == sequence else { return }

            self.failConnection("指令确认超时，为安全起见已断开")
        }
        commandTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func scheduleCommandResultReadFallback(after seconds: TimeInterval = 0.35) {
        responseReadFallback?.cancel()
        let session = connectionID
        let commandSeq = pendingCommandSequence
        let calibrationSeq = activeCalibrationSequence
        let read = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.connectionID == session,
                  self.setupStage == .ready,
                  let peripheral = self.connectedPeripheral,
                  let response = self.responseCharacteristic else { return }
    
            if let sequence = commandSeq {
                guard self.pendingCommandSequence == sequence,
                      self.pendingCommandWriteConfirmed else { return }
            } else if let sequence = calibrationSeq {
                guard self.activeCalibrationSequence == sequence else { return }
            } else {
                return
            }
    
            self.debugLog("命令结果通知未到达，回退读取 Response")
            peripheral.readValue(for: response)
        }
        responseReadFallback = read
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: read)
    }

    private func scheduleCalibrationResultTimeout(for sequence: UInt32) {
        calibrationResultTimeout?.cancel()
        let session = connectionID
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.connectionID == session,
                  self.activeCalibrationSequence == sequence else { return }
            self.failConnection("标定结果确认超时，为安全起见已断开")
        }
        calibrationResultTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

// MARK: 加密控制指令
    private func sendCommand(_ command: KeyCommand) {
        guard isConnected,
        isAuthenticated,
        authState == .authenticated,
        let peripheral = connectedPeripheral,
        let characteristic = commandCharacteristic else {
            statusText = "请先完成双向认证"
            return
        }
        guard pendingCommand == nil else{
            statusText = "上一条指令尚未确认，请稍后"
            return
        }
        guard !isCalibrationBusy else {
            statusText = "标定结果确认中，请稍后再发送指令"
            return
        }
        guard commandSequence < UInt32.max else{
            statusText = "指令序号已用尽，请重新连接"
            return
        }
        guard let sessionTag = commandSessionTag, sessionTag.count == 4 else{
            statusText = "认证会话信息无效，请重新连接"
            return
        }
        guard let padding = randomBytes(count: 7) else{
            statusText = "生成指令随机数失败"
            return
        }
        
        let sequence = commandSequence + 1
        var plaintext = [UInt8](repeating: 0, count: 16)
        plaintext[0] = command.rawValue
        plaintext[1] = UInt8(truncatingIfNeeded: sequence)
        plaintext[2] = UInt8(truncatingIfNeeded: sequence >> 8)
        plaintext[3] = UInt8(truncatingIfNeeded: sequence >> 16)
        plaintext[4] = UInt8(truncatingIfNeeded: sequence >> 24)
        plaintext.replaceSubrange(5..<9, with: sessionTag)
        plaintext.replaceSubrange(9..<16, with: padding)

        guard let encrypted = aesECBEncrypt(data: Data(plaintext)) else{
            statusText = "指令加密失败"
            return
        }

        optionalUpdatesWorkItem?.cancel()
        optionalUpdatesWorkItem = nil
        if command == .calibrateOneMeter {
            isCalibrationBusy = true
            calibrationResultText = nil
            calibrationSucceeded = false
        }

        commandSequence = sequence
        pendingCommand = command 
        pendingCommandSequence = sequence
        pendingCommandWriteConfirmed = false
        pendingCommandResult = nil
        statusText = "正在发送\(command.title)指令..."
        scheduleCommandTimeout(for: sequence, peripheral: peripheral)
        peripheral.writeValue(encrypted, for: characteristic, type: .withResponse)
    }

    //MARK 状态与随机数
    private func handleStatus(_ data: Data) {
        guard data.count == 1 else {
            if authState == .waitingForProofWrite || authState == .waitingForAuthenticationStatus {
                authenticationFailed("模块状态长度错误")
            }
            return
        }
        let status = data[0]
        let moduleAuthenticated = status & (1 << 0) != 0
        let wasAuthenticated = isAuthenticated
        let wasUnlocked = isUnlocked
        let wasCalibrating = isCalibrating
    
        isUnlocked = status & (1 << 1) != 0
        isNearStable = status & (1 << 2) != 0
        isCalibrating = status & (1 << 4) != 0
    
        if moduleAuthenticated {
            switch authState {
            case .waitingForProofWrite:
                // 模块通知可能先于 Proof 的 ATT 写确认，先缓存，不能提前开放指令。
                if !pendingAuthenticationStatus {
                    debugLog("认证成功状态早于 Proof 写确认到达，已缓存")
                }
                pendingAuthenticationStatus = true
            case .waitingForAuthenticationStatus:
                completeAuthentication()
            default:
                break
            }
        } else if authState == .waitingForAuthenticationStatus {
            authenticationFailed("模块未接受手机 Proof")
            return
        } else if wasAuthenticated || authState == .authenticated {
            failConnection("模块认证已失效，请重新连接")
            return
        }
    
        // UI 与发送指令使用同一判定。
        isAuthenticated = moduleAuthenticated && authState == .authenticated

        if isWaitingForProximity && isNearStable && isAuthenticated {
            finishUnlockWait(send: true)
        }
        
        if wasCalibrating && !isCalibrating && isCalibrationBusy,
           activeCalibrationSequence != nil {
            // 标定采样已结束但最终结果通知可能丢失，读取最新 Response 补齐。
            scheduleCommandResultReadFallback(after: 0.25)
        }

        // 周期 Status 只同步模块状态，绝不能当作某条命令的执行结果。
        if setupStage == .ready, pendingCommand == nil,
           wasUnlocked != isUnlocked || wasCalibrating != isCalibrating {
            if isCalibrating {
                statusText = "一米标定进行中，请保持手机静止"
            } else if !isCalibrationBusy {
                statusText = "模块状态已同步：当前\(isUnlocked ? "已解锁" : "已闭锁")"
            }
        }
    }

    private func handleCommandResult(_ data: Data) {
        guard data.count == commandResultLength,
              data[0] == commandResultMessageType else {
            debugLog("忽略未知 Response 数据：\(data.count) 字节")
            return
        }
        let rawCode = data[6]
        let result = CommandResult(
            command: data[1],
            sequence: UInt32(data[2]) |
                (UInt32(data[3]) << 8) |
                (UInt32(data[4]) << 16) |
                (UInt32(data[5]) << 24),
            code: CommandResultCode(rawValue: rawCode),
            rawCode: rawCode,
            status: data[7]
        )
        processCommandResult(result)
    }

    private func processCommandResult(_ result: CommandResult) {
        guard setupStage == .ready else {
            debugLog("忽略非就绪阶段的命令结果")
            return
        }
        // 标定开始后可异步返回最终结果，此时最初的命令等待已经结束。
        if result.command == KeyCommand.calibrateOneMeter.rawValue,
           result.sequence == activeCalibrationSequence {
            if result.code == .started {
                // Flash 尚未完成时 Read 可能仍得到 Started，继续读取直至最终结果到达。
                scheduleCommandResultReadFallback(after: 0.5)
            } else {
                finishCalibration(with: result)
            }
            return
        }
        guard let command = pendingCommand,
              command.rawValue == result.command,
              pendingCommandSequence == result.sequence else {
            debugLog("忽略过期或不匹配的命令结果：cmd=\(result.command) seq=\(result.sequence)")
            return
        }
        guard pendingCommandWriteConfirmed else {
            pendingCommandResult = result
            debugLog("命令结果早于 ATT 写确认到达，已缓存：seq=\(result.sequence)")
            return
        }
        completePendingCommand(command, with: result)
    }
    
    private func completePendingCommand(_ command: KeyCommand, with result: CommandResult) {
        resetPendingCommand()
        handleStatus(Data([result.status]))
        guard setupStage == .ready else { return }

        if command == .calibrateOneMeter {
            if result.code == .started {
                activeCalibrationSequence = result.sequence
                isCalibrationBusy = true
                calibrationResultText = nil
                calibrationSucceeded = false
                statusText = "一米标定进行中，请保持手机在 1 米处静止"
                scheduleCalibrationResultTimeout(for: result.sequence)
                scheduleCommandResultReadFallback(after: 3.5)
            } else {
                finishCalibration(with: result)
            }
            return
        }
    
        switch result.code {
        case .success:
            statusText = "\(command.title)完成：当前\(isUnlocked ? "已解锁" : "已闭锁")"
        case .notNear:
            statusText = "解锁失败：请靠近车辆并保持信号稳定"
        case .busy:
            statusText = "\(command.title)失败：模块忙"
        case .replayed:
            statusText = "\(command.title)失败：序号无效或重复"
        case .sessionRejected:
            statusText = "\(command.title)失败：认证会话不匹配"
        case .unsupported:
            statusText = "模块不支持\(command.title)指令"
        case .rejected:
        statusText = "\(command.title)指令被模块拒绝"
        default:
            statusText = "\(command.title)失败：结果码 \(result.rawCode)"
        }
        scheduleOptionalUpdates(after: 0.5)
    }
            
    private func finishCalibration(with result: CommandResult) {
        calibrationResultTimeout?.cancel()
        responseReadFallback?.cancel()
        calibrationResultTimeout = nil
        responseReadFallback = nil
        activeCalibrationSequence = nil
        isCalibrationBusy = false
        handleStatus(Data([result.status]))
        guard setupStage == .ready else { return }

        switch result.code {
        case .success:
            calibrationSucceeded = true
            calibrationResultText = "标定完成，1 米阈值已保存"
        case .insufficientSamples:
            calibrationSucceeded = false
            calibrationResultText = "标定失败：有效 RSSI 样本不足"
        case .invalidRSSI:
            calibrationSucceeded = false
            calibrationResultText = "标定失败：RSSI 不在有效范围"
        case .storageError:
            calibrationSucceeded = false
            calibrationResultText = "标定值已生效，但 Flash 保存失败"
        case .busy:
            calibrationSucceeded = false
            calibrationResultText = "标定失败：Flash 存储忙"
        default:
            calibrationSucceeded = false
            calibrationResultText = "标定失败：结果码 \(result.rawCode)"
        }
        statusText = calibrationResultText ?? "标定已结束"
        scheduleOptionalUpdates(after: 0.5)
    }

    private func randomBytes(count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return result == errSecSuccess ? bytes : nil
    }
    // MARK: - AES-128-ECB
    private func aesECBEncrypt(data: Data) -> Data? {
        return crypt(data: data, operation: CCOperation(kCCEncrypt))
    }
    
    private func aesECBDecrypt(data: Data) -> Data? {
        return crypt(data: data, operation: CCOperation(kCCDecrypt))
    }
    
    private func crypt(data: Data, operation: CCOperation) -> Data? {
        guard data.count == kCCBlockSizeAES128 else { return nil }
        
        var outLength = 0
        var outBytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let inputBytes = [UInt8](data)
        
        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),                 // 纯 ECB，不加 PKCS7
            aesKey,
            kCCKeySizeAES128,
            nil,
            inputBytes,
            inputBytes.count,
            &outBytes,
            kCCBlockSizeAES128,
            &outLength
        )
        
        guard status == kCCSuccess, outLength ==  kCCBlockSizeAES128 else {
            print("CCCrypt error: \(status)")
            return nil
        }
        
        return Data(outBytes)
    }
}
// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        resetConnectionTiming()
        let peripherals = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let candidates: [CBPeripheral]
        if let identifier = pairedPeripheralIdentifier {
            candidates = peripherals.filter { $0.identifier == identifier }
        } else {
            candidates = peripherals
        }
        guard let peripheral = candidates.first(where: { $0.state == .connected }) ??
              candidates.first(where: { $0.state == .connecting }) ?? candidates.first else {
            debugLog("忽略未配对模块的状态恢复记录")
            return
        }

        // 此时蓝牙尚未 poweredOn，不能发起任何 GATT 或连接操作，留到 poweredOn 处理。
        restoredPeripheral = peripheral
        peripheral.delegate = self
        debugLog("恢复 iOS 保存的蓝牙状态: \(peripheral.identifier.uuidString)")
    }

    private func resumeRestoredPeripheral(_ peripheral: CBPeripheral) {
        centralManager.stopScan()
        switch peripheral.state {
        case .connected:
            // 只恢复服务发现和双向认证，不自动发送任何控制指令。
            connectedPeripheral = peripheral
            peripheral.delegate = self
            beginServiceDiscovery(for: peripheral)
        case .connecting:
            connectedPeripheral = peripheral
            peripheral.delegate = self
            statusText = "等待固定模块进入范围..."
            scheduleDirectFallbackScan(for: peripheral)

        default:
            connect(to: peripheral, directReconnect: true)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        func handleUnavailable(_ message: String) {
            let peripheral = connectedPeripheral
            central.stopScan()
            clearConnectionState()
            if let peripheral = peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            statusText = message
        }
    
        switch central.state {
        case .poweredOn:
            if let restored = restoredPeripheral, autoConnectEnabled {
                restoredPeripheral = nil
                resumeRestoredPeripheral(restored)
            } else if connectedPeripheral == nil && autoConnectEnabled {
                startScan()
            } else if !autoConnectEnabled {
                statusText = "蓝牙已开启，自动连接已暂停"
            }
        case .poweredOff:
            handleUnavailable("蓝牙已关闭")
        case .unauthorized:
            handleUnavailable("没有蓝牙权限")
        case .unsupported:
            handleUnavailable("当前设备不支持蓝牙")
        case .resetting:
            handleUnavailable("蓝牙正在复位")
        case .unknown:
            handleUnavailable("蓝牙状态未知")
        @unknown default:
            handleUnavailable("蓝牙不可用")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard autoConnectEnabled,
              !ignoredPeripheralIdentifiers.contains(peripheral.identifier) else { return }

        // 并行扫描时已配对模块的挂起连接仍在，只有发现其他模块才需要切换。
        let pendingDirectPeripheral = isFallbackScanActive ? connectedPeripheral : nil
        if isFallbackScanActive {
            guard let pending = pendingDirectPeripheral,
                  pending.state == .connecting,
                  pending.identifier != peripheral.identifier else { return }
        } else {
            guard connectedPeripheral == nil else { return }
        }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard advertisedName == deviceName || peripheral.name == deviceName ||
              advertisedServices.contains(serviceUUID) else { return }
        logConnectionTiming("扫描发现固定模块, RSSI \(RSSI.intValue) dBm")
        connect(to: peripheral)
        if let pendingDirectPeripheral = pendingDirectPeripheral {
            central.cancelPeripheralConnection(pendingDirectPeripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectedPeripheral === peripheral else { return }
        logConnectionTiming("BLE 链路已连接")
        beginServiceDiscovery(for: peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, 
                        error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        failConnection("连接失败: \(error?.localizedDescription ?? "未知错误")", linkLost: true)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, 
                        error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        let message = error.map{ "连接断开: \($0.localizedDescription)"} ?? "连接已断开"
        failConnection(message, linkLost: true)
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectedPeripheral === peripheral else { return }

        if setupStage == .ready {
            if let error = error {
                 debugLog("电量服务发现失败：\(error.localizedDescription)")
                return
            }
            if let batteryService = peripheral.services?.first(where: {
                $0.uuid == batteryServiceUUID
            }) {
                peripheral.discoverCharacteristics([batteryLevelUUID], for: batteryService)
            } else {
                debugLog("模块未提供标准电量服务，不影响解锁")
            }
            return
        }
        guard setupStage == .discoveringServices else { return }
        if let error = error{
            failConnection ("服务发现失败：\(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        let discoveredUUIDs = services.map { $0.uuid.uuidString }
        debugLog("发现 \(services.count) 个服务：\(discoveredUUIDs.joined(separator:","))")
        guard let service = services.first(where: { $0.uuid == serviceUUID }) else {
            let detail = services.isEmpty
            ? "服务列表为空"
            : "实际服务：\(discoveredUUIDs.joined(separator:","))"
            failConnection ("未找到车钥匙服务：\(detail)")
            return
        }
        setupStage = .discoveringCharacteristics
        statusText = "已找到车钥匙服务，正在发现特征..."
        debugLog("服务发现成功，开始发现特征")
        logConnectionTiming("车钥匙服务发现完成")
        schedulePhaseTimeout(message: "特征发现超时",peripheral: peripheral)
        peripheral.discoverCharacteristics([
            challengeUUID,
            responseUUID,
            commandUUID,
            rssiUUID,
            statusUUID
        ], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard connectedPeripheral === peripheral else { return }

        if service.uuid == batteryServiceUUID {
            if let error = error {
                debugLog("电量特征发现失败: \(error.localizedDescription)")
                return 
            }
            guard let battery = service.characteristics?.first(where: {
                $0.uuid == batteryLevelUUID
            })else{
                debugLog("未找到标准电量特征 2A19")
                return 
            }

            batteryCharacteristic = battery
            debugLog("发现标准电量特征，读取并订阅 Notify")
            if battery.properties.contains(.read) {
                peripheral.readValue(for: battery)
            }
            if battery.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: battery)
            }
            return
        }
        guard service.uuid == serviceUUID,
              setupStage == .discoveringCharacteristics else { return }
        if let error = error {
            failConnection ("特征发现失败：\(error.localizedDescription)")
            return
        }

        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            debugLog("发现特征 \(characteristic.uuid.uuidString)，属性 \(characteristic.properties.rawValue)")
            switch characteristic.uuid {
            case challengeUUID:
                challengeCharacteristic = characteristic
            case responseUUID:
                responseCharacteristic = characteristic
            case commandUUID:
                commandCharacteristic = characteristic
            case rssiUUID:
                rssiCharacteristic = characteristic
            case statusUUID:
                statusCharacteristic = characteristic
            default:
                break
            }
        }

        statusText = "特征发现完成，正在校验模块能力"
        logConnectionTiming("车钥匙特征发现完成")
        prepareAuthentication()
    }
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral === peripheral else { return }

        if characteristic.uuid == batteryLevelUUID {
            if let error = error {
                debugLog("订阅电量通知失败：\(error.localizedDescription)")
            } else {
                 debugLog("电量通知状态：\(characteristic.isNotifying ? "已开启" : "已关闭")")
            }
            return
        }
        
        if characteristic.uuid == rssiUUID {
            if let error = error {
                debugLog("订阅 RSSI 通知失败：\(error.localizedDescription)")
            } else {
                debugLog("RSSI 通知状态：\(characteristic.isNotifying ? "已开启" : "已关闭")")
            }
            return
        }
        guard characteristic.uuid == responseUUID || characteristic.uuid == statusUUID else { return }
        
        if let error = error {
                failConnection("订阅\(characteristic.uuid.uuidString)失败：\(error.localizedDescription)")
                return
            }
        

        guard characteristic.isNotifying else { 
                failConnection("模块通知未开启：\(characteristic.uuid.uuidString)")
                return      
        }
        notificationSubscriptionCompleted(characteristic, for: peripheral)
    }

func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        if let error = error {
            switch characteristic.uuid {
            case responseUUID:
                if authState == .waitingForModuleResponse {
                    authenticationFailed("读取认证响应失败：\(error.localizedDescription)")
                } else if pendingCommand != nil || activeCalibrationSequence != nil {
                    failConnection("读取命令结果失败：\(error.localizedDescription)，为安全起见已断开")
                }
            case statusUUID:
                if authState == .waitingForAuthenticationStatus {
                    authenticationFailed("读取认证状态失败：\(error.localizedDescription)")
                }
            case batteryLevelUUID:
                debugLog("读取电量失败：\(error.localizedDescription)")
            default:
                break
            }
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case responseUUID:
            if data.count == commandResultLength, data[0] == commandResultMessageType {
                handleCommandResult(data)
            } else {
                handleModuleResponse(data)
            }
        case rssiUUID:
            guard data.count == 1 else { return }
            filteredRSSI = Int(Int8(bitPattern: data[0]))
        case statusUUID:
            handleStatus(data)
        case batteryLevelUUID:
            guard data.count == 1, data[0] <= 100 else { 
                debugLog("电量数据长度或数值无效")      
                return
            }
            batteryLevel = Int(data[0])
            debugLog("电池电量：\(data[0])%")      
        default:
            break
        }
    }

func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral === peripheral else { return }

        switch characteristic.uuid {
        case challengeUUID:
            if let error = error {
                authenticationFailed("认证写入失败：\(error.localizedDescription)")
                return
            }
            guard setupStage == .authenticating else { return }
            switch authState {
            case .waitingForChallengeWrite:
                authState = .waitingForModuleResponse
                statusText = "Challenge 写入成功，等待模块响应..."
                debugLog("Challenge 写入成功，等待32字节模块响应")
                if let earlyResponse = pendingModuleResponse {
                    handleModuleResponse(earlyResponse)
                } else {
                    schedulePhaseTimeout(after:8,
                                        message: "认证超时：未收到模块响应",
                                        peripheral: peripheral)
                    scheduleResponseReadFallback()
                }
            case .waitingForProofWrite:
                authState = .waitingForAuthenticationStatus
                statusText = "proof写入成功，等待模块认证状态..."
                if pendingAuthenticationStatus {
                    debugLog("Proof 写确认到达，消费提前到达的认证成功状态")
                    completeAuthentication()
                    return
                }
                debugLog("Proof 写入成功，读取模块状态")
                schedulePhaseTimeout(after: 8,
                                     message: "认证超时：未收到模块认证状态",
                                    peripheral: peripheral)
                guard let status = statusCharacteristic else{
                    authenticationFailed("模块状态特征不可用")
                    return
                }
                peripheral.readValue(for: status)
            default:
                break
            }

        case commandUUID:
            guard let command = pendingCommand, pendingCommandSequence != nil else { return }
            if let error = error {
                resetPendingCommand()
                if command == .calibrateOneMeter {
                    calibrationResultTimeout?.cancel()
                    calibrationResultTimeout = nil
                    activeCalibrationSequence = nil
                    isCalibrationBusy = false
                    calibrationSucceeded = false
                    calibrationResultText = "标定指令写入失败：\(error.localizedDescription)"
                }
                statusText = "\(command.title)指令写入失败：\(error.localizedDescription)"
                scheduleOptionalUpdates(after: 0.5)
                return
            }
        
            // ATT 写确认只证明请求已写入；执行结果必须匹配命令和序号。
            pendingCommandWriteConfirmed = true
            statusText = "\(command.title)指令已发送，等待模块结果"
            if let earlyResult = pendingCommandResult {
                processCommandResult(earlyResult)
            } else {
                scheduleCommandResultReadFallback()
            }

        default:
            break
        }
    }
}


