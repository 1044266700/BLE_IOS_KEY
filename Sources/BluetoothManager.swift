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
    private let lastPeripheralKey = "LastConnectedPeripheralUUID"
    
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
    private var phoneNonce: Data?

    private var commandSequence: UInt32 = 0
    private var pendingCommand: KeyCommand?
    
    private var connectionTimeout: DispatchWorkItem?
    private var authenticationTimeout: DispatchWorkItem?
    private var responseReadFallback: DispatchWorkItem?
    
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
                statusText = peripheral.state == .connected ? "设备已连接" ： "正在连接设备..."
                return
            }
        centralManager.stopScan()
        clearConnectionState()
        isScanning = true
        statusText = "正在扫描 BLE_KEY..."

        
        // 优先重连上次成功的外设
        if let uuidString = UserDefaults.standard.string(forKey: lastPeripheralKey),
           let uuid = UUID(uuidString: uuidString) {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = known.first, peripheral.name == deviceName {
                connect(to: peripheral)
                return
            }
        }
        
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    func disconnect() {
        let peripheral = connectedPeripheral 
        clearConnectionState()
        if let peripheral = peripheral{
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        statusText = "已断开"
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
        centralManager.connect(peripheral, options: nil)
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self,
                  let peripheral = peripheral,
                  self.connectedPeripheral === peripheral,
                  peripheral.state == .connecting else { return }
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.clearConnectionState()
            self.statusText = "连接超时，请靠近重试"
        }
    connectionTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
}
    
    private func clearConnectionState() {
        connectionTimeout?.cancel()
        authenticationTimeout?.cancel()
        responseReadFallback?.cancel()
        connectionTimeout = nil
        authenticationTimeout = nil
        responseReadFallback = nil
        isConnected = false
        isScanning = false
        filteredRSSI = nil
        isUnlocked = false
        isNearStable = false
        isApproachArmed = false
        isCalibrating = false

        authState = .idle
        phoneNonce = nil
        commandSequence = 0
        pendingCommand = nil
        
        challengeCharacteristic = nil
        responseCharacteristic = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        connectedPeripheral = nil
        rssiCharacteristic = nil
    }

    // MARK: - 双向认证
    private func prepareAuthentication() {
        guard let peripheral = connectedPeripheral,
              let response = responseCharacteristic,
              challengeCharacteristic != nil,
              commandCharacteristic != nil,
              let rssi = rssiCharacteristic,
              let status = statusCharacteristic else {
            authenticationFailed("模块特征不完整，无法认证")
            return
        }

        authState = .waitingForResponseNotification
        isAuthenticated = false
        statusText = "正在订阅模块通知..."

        peripheral.setNotifyValue(true, for: response)
        peripheral.setNotifyValue(true, for: status)
        peripheral.setNotifyValue(true, for: rssi)
        peripheral.readValue(for: status)
        peripheral.readValue(for: rssi)

        scheduleAuthenticationTimeout()

        // 已订阅时无需再次等待 CCCD 回调。
        if response.isNotifying {
            startAuthentication()
        }
    }
//TODO
    private func startAuthentication() {
        guard let peripheral = connectedPeripheral,
              let characteristic = challengeCharacteristic,
              authState == .waitingForResponseNotification || authState == .idle,
              let nonce = randomBytes(count: 16) else {
            if authState != .authenticated {
                authenticationFailed("无法开始认证")
            }
            return
        }

        phoneNonce = Data(nonce)
        authState = .waitingForChallengeWrite
        isAuthenticated = false
        statusText = "正在进行双向认证..."

        // 第一步必须写原始 phone_nonce，由模块计算 AES(phone_nonce)。
        peripheral.writeValue(Data(nonce), for: characteristic, type: .withResponse)
    }

    private func handleModuleResponse(_ data: Data){
        guard authState == .waitingForModuleResponse else { return }
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
            peripheral == connectedPeripheral,
            let challenge = challengeCharacteristic else{
            authenticationFailed("生成手机认证应答失败")
            return
        }
        responseReadFallback?.cancel()
        responseReadFallback = nil
        phoneNone = nil
        authState = .waitingForProofWrite
        stateText = "模块已验证，正在验证手机..."

        // 第二步返回 AES(module_nonce)，此时还不能宣告双向认证成功。
        peripheral.writeValue(proof, for: challenge, type: .withResponse)
    }
    private func completeAuthentication(){
        authenticationTimeout?.cancel()
        responseReadFallback?.cancel()
        authenticationTimeout = nil
        responseReadFallback = nil
        phoneNone = nil
        commandSequence = 0
        authState = .authenticated
        isAuthenticated = true
        statusText = "双向认证完成"
    }   
    private func authenticationFailed(){
        authenticationTimeout?.cancel()
        responseReadFallback?.cancel()
        authenticationTimeout = nil
        responseReadFallback = nil
        phoneNone = nil
        authState = .idle
        isAuthenticated = false
        statusText = message
    }
    private func scheduleAuthenticationTimeout(){
        authenticationTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self,
                self.isConnected,
                self.authState != .authenticated else { return }
                self.authenticationFailed("认证超时，请断开后重新连接")
            }
        authenticationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
    private func scheduleResponseReadFallback(){
        responseReadFallback?.cancel()
        let read = DispatchWorkItem { [weak self] in
            guard let self = self,
                self.authState == .waitingForModuleResponse,
                let peripheral = self.connectedPeripheral,
                let response = self.responseCharacteristic else { return }
                peripheral.readValue(for:response)                     
            }
        responseReadFallback  = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: read)
    }

    private func sendCommand(_ command: KeyCommand) {
        guard isConnected,
        isAuthenticated,
        authState == .authenticated,
        let peripheral = connectedPeripheral,
        let characteristic = commandCharacteristic else {
            statusText = "请先完成双向认证"
            return
        }
        guard pendingCommand = nil else{
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
        pendingCommand = pendingCommand = command 
        statusText = "正在发送\(command.title)指令..."
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

        isAuthenticated = moduleAuthenticated
        isUnlocked = status & (1 << 1) != 0
        isNearStable = status & (1 << 2) != 0
        isApproachArmed = status & (1 << 3) != 0
        isCalibrating = status & (1 << 4) != 0

        ifmoduleAuthenticated && authState != .authenticated {
            completeAuthentication()
        }else if !moduleAuthenticated && (wasAuthenticated || authState == .authenticated){
            authState = .idle
            pendingCommand = nil
            statusText = "模块认证已失效，请重新连接"
        }
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
        
        guard status == kCCSuccess, outLength ==  kCCKeySizeAES128 else {
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
    
    func centralManager(_ central: CBCentralManager, didDiscover c: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard connectedPeripheral == nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard advertisedName = deviceName || peripheral.name == deviceName else { return }
        connect(to: peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectedPeripheral === peripheral else { return }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        isConnected = true
        isScanning = false
        statusText = "已连接，正在发现服务..."
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralKey)
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, 
                        error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        clearConnectionState()
        statusText = "连接失败: \(error?.localizedDescription ?? "未知错误")"
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, 
                        error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        clearConnectionState()
        if let error = error {
            statusText = "连接断开: \(error?.localizedDescription)"
        } else {
            statusText = "连接已断开"
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        if let error = error{
            statusText = "服务发现失败: \(error?.localizedDescription)"
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            statusText = "未找到车钥匙服务"
            return
        }

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
        guard connectedPeripheral === peripheral, service.uuid == serviceUUID else { return }
        if let error = error {
            statusText = "特征发现失败：\(error.localizedDescription)"
            return
        }

        for characteristic in service.characteristics ?? [] {
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

        prepareAuthentication()
    }
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral === peripheral else { return }
        if let error = error {
            if characteristic.uuid == responseUUID {
                authenticationFailed("订阅认证响应失败：\(error.localizedDescription)")
            } else {
                statusText = "订阅通知失败：\(error.localizedDescription)"
            }
            return
        }

        guard characteristic.uuid == responseUUID else { return }
        if characteristic.isNotifying {
            if authState == .waitingForResponseNotification {
                startAuthentication()
            }
        } else if authState != .authenticated {
            authenticationFailed("认证响应通知未开启")
        }
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

            switch authState {
            case .waitingForChallengeWrite:
                authState = .waitingForModuleResponse
                statusText = "等待模块认证响应..."
                scheduleResponseReadFallback()
            case .waitingForProofWrite:
                authState = .waitingForAuthenticationStatus
                statusText = "等待模块确认双向认证..."
                if let status = statusCharacteristic {
                    peripheral.readValue(for: status)
                }
            default:
                break
            }

        case commandUUID:
            let command = pendingCommand
            pendingCommand = nil
            if let error = error {
                statusText = "\(command?.title ?? "控制")指令写入失败：\(error.localizedDescription)"
            } else {
                // ATT 写确认不代表解锁条件已满足，实际结果以 Status 通知为准。
                statusText = "\(command?.title ?? "控制")指令已发送，等待模块状态"
            }

        default:
            break
        }
    }
}


