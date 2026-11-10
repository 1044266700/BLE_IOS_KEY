import Foundation
import CoreBluetooth
import CommonCrypto
import Combine
import Security

class BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - 公开状态
    @Published var statusText: String = "未连接"
    @Published var isConnected: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var isScanning: Bool = false
    @Published var filteredRSSI: Int?
    @Published var isUnlocked: Bool = false
    @Published var isNearStable: Bool = false
    @Published var isApproachArmed: Bool = false
    @Published var isCalibrating: Bool = false

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
        case subscribingNotifications
        case authenticating
        case ready
    }

    private enum NotificationSubscription {
        case none
        case response
        case status
        case rssi
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
    // MARK: - 私有属性
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    
    private var challengeCharacteristic: CBCharacteristic?   
    private var responseCharacteristic: CBCharacteristic?    
    private var commandCharacteristic: CBCharacteristic?   
    private var rssiCharacteristic: CBCharacteristic?    
    private var statusCharacteristic: CBCharacteristic?    

    private let deviceName = "BLE_KEY"
    //private let lastPeripheralKey = "LastConnectedPeripheralUUID.v2"
    
    private let serviceUUID     = CBUUID(string: "00000001-12BC-4A5E-9C01-23456789ABCD")
    private let challengeUUID   = CBUUID(string: "00000002-12BC-4A5E-9C01-23456789ABCD")
    private let responseUUID    = CBUUID(string: "00000003-12BC-4A5E-9C01-23456789ABCD")
    private let commandUUID     = CBUUID(string: "00000004-12BC-4A5E-9C01-23456789ABCD")
    private let rssiUUID        = CBUUID(string: "00000005-12BC-4A5E-9C01-23456789ABCD")
    private let statusUUID      = CBUUID(string: "00000006-12BC-4A5E-9C01-23456789ABCD")
    // =====================================================
    
    //蓝牙设备号唯一
    private let aesKey: [UInt8] = [
        0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
        0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F,0x3C
    ]
    private var authState: AuthenticationState = .idle
    private var setupStage: SetupStage = .idle
    private var subscriptionStep: NotificationSubscription = .none
    private var phoneNonce: Data?
    private var connectionID: UInt = 0

    private var commandSequence: UInt32 = 0
    private var pendingCommand: KeyCommand?
    private var pendingCommandSequence: UInt32?
    
    private var connectionTimeout: DispatchWorkItem?
    private var phaseTimeout: DispatchWorkItem?
    private var responseReadFallback: DispatchWorkItem?
    private var commandTimeout: DispatchWorkItem?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - 对外方法
    func startScan() {
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
        isScanning = true
        statusText = "正在扫描 BLE_KEY..."

        
        // 优先重连上次成功的外设
        // if let uuidString = UserDefaults.standard.string(forKey: lastPeripheralKey),
        //    let uuid = UUID(uuidString: uuidString) {
        //     let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        //     if let peripheral = known.first, peripheral.name == deviceName {
        //         connect(to: peripheral)
        //         return
        //     }
        // }
        
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    func disconnect() {
        failConnection ("已断开")
    }
    
    func unlock() {
        sendCommand(.unlock)
    }
    func lock() {
        sendCommand(.lock)
    }
    func calibrateAtOneMeter() {
        sendCommand(.calibrateOneMeter)
    }

    private func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        clearConnectionState()
        
        connectedPeripheral = peripheral
        peripheral.delegate = self
        statusText = "正在连接 \(deviceName)..."
        debugLog("开始连接 \(peripheral.identifier.uuidString)")
        centralManager.connect(peripheral, options: nil)
        let session = connectionID
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self,
            let peripheral = peripheral,
            self.connectionID == session,
            self.connectedPeripheral === peripheral,
            peripheral.state == .connecting else { return }
            self.failConnection("连接超时，请靠近重试")
        }
    connectionTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
}
    private func failConnection(_ message: String) {
        let peripheral = connectedPeripheral
        debugLog(message)
        centralManager.stopScan()
        clearConnectionState()
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        statusText = message
    }

    private func clearConnectionState() {
        connectionID &+= 1
        connectionTimeout?.cancel()
        phaseTimeout?.cancel()
        responseReadFallback?.cancel()
        commandTimeout?.cancel()
        connectionTimeout = nil
        phaseTimeout = nil
        responseReadFallback = nil
        commandTimeout = nil
        
        isConnected = false
        isScanning = false
        isAuthenticated = false
        filteredRSSI = nil
        isUnlocked = false
        isNearStable = false
        isApproachArmed = false
        isCalibrating = false

        authState = .idle
        setupStage = .idle
        subscriptionStep = .none
        phoneNonce = nil
        commandSequence = 0
        pendingCommand = nil
        pendingCommandSequence = nil
        
        challengeCharacteristic = nil
        responseCharacteristic = nil
        commandCharacteristic = nil
        rssiCharacteristic = nil
        statusCharacteristic = nil
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
    }
    private func debugLog(_ message: String){
        print("[BLE_KEY] \(message)")
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
              let rssi = rssiCharacteristic,
              let status = statusCharacteristic, 
              challenge.properties.contains(.write),
              response.properties.contains(.read),
              response.properties.contains(.notify),
              command.properties.contains(.write),
              rssi.properties.contains(.read),
              rssi.properties.contains(.notify),
              status.properties.contains(.read),
              status.properties.contains(.notify) else {
            authenticationFailed("模块特征不完整，无法认证")
            return
        }
        
        setupStage = .subscribingNotifications
        authState = .waitingForResponseNotification
        isAuthenticated = false
        beginNotificationSubscription(.response)
    }
    private func beginNotificationSubscription(_ step: NotificationSubscription) {
        guard let peripheral = connectedPeripheral,
              setupStage == .subscribingNotifications else { return }

        let characteristic: CBCharacteristic
        let title: String
        switch step {
            case .response:
                guard let response = responseCharacteristic else { return }
                characteristic = response
                title = "认证响应 （1/3）"
            case .status:
                guard let status = statusCharacteristic else { return }
                characteristic = status
                title = "模块状态 （2/3）"
            case .rssi:
                guard let rssi = rssiCharacteristic else { return }
                characteristic = rssi
                title = "rssi （3/3）"
            case .none:
                return
        }
        subscriptionStep = step
        statusText = "正在订阅\(title)通知..."
        debugLog("订阅 \(characteristic.uuid.uuidString)")
        schedulePhaseTimeout(after:8,
                            message: "订阅\(title)通知超时",
                            peripheral: peripheral)

        if characteristic.isNotifying {
            notificationSubscriptionCompleted(characteristic, for: peripheral)
        } else {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func notificationSubscriptionCompleted(_ characteristic: CBCharacteristic,
                                                  for peripheral: CBPeripheral){
        guard connectedPeripheral === peripheral,
              setupStage == .subscribingNotifications else { return }
              debugLog("已订阅 \(characteristic.uuid.uuidString)")

              switch characteristic.uuid {
              case responseUUID:
                  guard subscriptionStep == .response else { return }
                  beginNotificationSubscription(.status)
              case statusUUID:
                  guard subscriptionStep == .status else { return }
                  beginNotificationSubscription(.rssi)
              case rssiUUID:
                  guard subscriptionStep == .rssi else { return }
                  subscriptionStep = .none
                  setupStage = .authenticating
                  startAuthentication()
              default :
                  break
        }
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
        authState = .waitingForChallengeWrite
        isAuthenticated = false
        statusText = "通知订阅完成，正在发送Challenge..."
        debugLog("发送16字节Challenge")
        schedulePhaseTimeout(after:8,
                    message: "认证超时：challenge写入未确认",
                    peripheral: peripheral)
        // 第一步必须写原始 phone_nonce，由模块计算 AES(phone_nonce)。
        peripheral.writeValue(Data(nonce), for: characteristic, type: .withResponse)
    }

    private func handleModuleResponse(_ data: Data){
        guard setupStage == .authenticating,
             authState == .waitingForModuleResponse else { return }
        guard data.count == 32 else{
            authenticationFailed("认证长度错误 ： \(data.count)字节")
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
        authState = .waitingForProofWrite
        statusText = "模块已验证，正在验证手机..."
        debugLog("模块响应校验通过，发送proof")
        schedulePhaseTimeout(after:8,
                    message: "认证超时：proof写入未确认",
                    peripheral: peripheral)

        // 第二步返回 AES(module_nonce)，此时还不能宣告双向认证成功。
        peripheral.writeValue(proof, for: challenge, type: .withResponse)
    }
    private func completeAuthentication(){
        phaseTimeout?.cancel()
        responseReadFallback?.cancel()
        phaseTimeout = nil
        responseReadFallback = nil
        phoneNonce = nil
        commandSequence = 0
        setupStage = .ready
        authState = .authenticated
        isAuthenticated = true
        statusText = "双向认证完成"
        debugLog("双向认证完成")
    }   
    private func authenticationFailed(_ message: String){
        // 认证失败后模块可能还在等待proof
        failConnection(message)
    }
    // private func scheduleAuthenticationTimeout(){
    //     authenticationTimeout?.cancel()
    //     let timeout = DispatchWorkItem { [weak self] in
    //         guard let self = self,
    //             self.isConnected,
    //             self.authState != .authenticated else { return }
    //             self.authenticationFailed("认证超时，请断开后重新连接")
    //         }
    //     authenticationTimeout = timeout
    //     DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    // }
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
        guard commandSequence < UInt32.max else{
            statusText = "指令序号已用尽，请重新连接"
            return
        }
        guard let padding = randomBytes(count: 11) else{
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
        plaintext.replaceSubrange(5..<16, with: padding)

        guard let encrypted = aesECBEncrypt(data: Data(plaintext)) else{
            statusText = "指令加密失败"
            return
        }


        commandSequence = sequence
        pendingCommand = command 
        pendingCommandSequence = sequence
        statusText = "正在发送\(command.title)指令..."
        scheduleCommandTimeout(for: sequence, peripheral: peripheral)
        peripheral.writeValue(encrypted, for: characteristic, type: .withResponse)
    }

//MARK 状态与随机数
    private func handleStatus(_ data: Data) {
        guard data.count == 1 else{
            if authState == .waitingForAuthenticationStatus {
                authenticationFailed("模块状态长度错误")
            }
            return
        }
        let status = data[0]
        let moduleAuthenticated  = status & (1 << 0) != 0
        let  wasAuthenticated = isAuthenticated

        isUnlocked = status & (1 << 1) != 0
        isNearStable = status & (1 << 2) != 0
        isApproachArmed = status & (1 << 3) != 0
        isCalibrating = status & (1 << 4) != 0

        if moduleAuthenticated  {
            //只有手机 proof已发出后，才接受模块的认证成功状态
            if authState == .waitingForProofWrite || authState == .waitingForAuthenticationStatus{
                completeAuthentication()
            }
        }
        else if !moduleAuthenticated && (wasAuthenticated || authState == .authenticated){
            failConnection ("模块认证已失效，请重新连接")
            return 
        }
        // UI 与发送指令使用同一判定
        isAuthenticated = moduleAuthenticated && authState == .authenticated
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
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if connectedPeripheral == nil && !isScanning {
                statusText = "蓝牙已开启，可以开始扫描"
            }
        case .poweredOff:
            clearConnectionState()
            statusText = "蓝牙已关闭"
        case .unauthorized:
            clearConnectionState()
            statusText = "没有蓝牙权限"
        case .unsupported:
            clearConnectionState()
            statusText = "当前设备不支持蓝牙"
        default:
            statusText = "蓝牙不可用"
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard connectedPeripheral == nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard advertisedName == deviceName || peripheral.name == deviceName else { return }
        connect(to: peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectedPeripheral === peripheral else { return }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        isConnected = true
        isScanning = false
        setupStage = .discoveringServices
        statusText = "已连接，正在发现服务..."
        debugLog("BLE 已连接，开始发现服务")
        //UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralKey)
         schedulePhaseTimeout(message: "服务发现超时",peripheral: peripheral)
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, 
                        error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        let message = "连接失败: \(error?.localizedDescription ?? "未知错误")"
        debugLog(message)
        clearConnectionState()
        statusText = message
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, 
                        error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        let message = error.map{ "连接断开: \($0.localizedDescription)"} ?? "连接已断开"
        debugLog(message)
        clearConnectionState()
        statusText = message
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectedPeripheral === peripheral,
              setupStage == .discoveringServices else { return }
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
        guard connectedPeripheral === peripheral,
              service.uuid == serviceUUID,
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
        prepareAuthentication()
    }
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        guard characteristic.uuid == responseUUID ||
              characteristic.uuid == statusUUID ||
              characteristic.uuid == rssiUUID else {return}
        
        if let error = error {
                failConnection("订阅\(characteristic.uuid.uuidString)失败：\(error.localizedDescription)")
                return
            }
        

        guard characteristic.isNotifying else { 
                failConnection("通知模块未开启：\(characteristic.uuid.uuidString)")
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
                }
            case statusUUID:
                if authState == .waitingForAuthenticationStatus {
                    authenticationFailed("读取认证状态失败：\(error.localizedDescription)")
                }
            default:
                break
            }
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case responseUUID:
            handleModuleResponse(data)
        case rssiUUID:
            guard data.count == 1 else { return }
            filteredRSSI = Int(Int8(bitPattern: data[0]))
        case statusUUID:
            handleStatus(data)
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
                statusText = "Challeng 写入成功，等待模块响应..."
                debugLog("Challeng 写入成功，等待32字节模块响应")
                schedulePhaseTimeout(after:8,
                                    message: "认证超时：未收到模块响应",
                                    peripheral: peripheral)
                scheduleResponseReadFallback()
            case .waitingForProofWrite:
                authState = .waitingForAuthenticationStatus
                statusText = "proof写入成功，等待模块认证状态..."
                debugLog("proof写入成功，等待模块认证状态")
                schedulePhaseTimeout(after:8,
                                    message: "认证超时：未收到模块认证响应",
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
            commandTimeout?.cancel()
            commandTimeout = nil
            pendingCommand = nil
            pendingCommandSequence = nil
            if let error = error {
                statusText = "\(command.title)指令写入失败：\(error.localizedDescription)"
            } else {
                // ATT 写确认不代表解锁条件已满足，实际结果以 Status 通知为准。
                statusText = "\(command.title)指令已发送，等待模块状态"
            }

        default:
            break
        }
    }
}


