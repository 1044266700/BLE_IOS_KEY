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
        
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
    
    func disconnect() {
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        resetState()
    }
    
    func unlock() {
        guard isAuthenticated, let characteristic = commandCharacteristic else {
            statusText = "请先完成认证"
            return
        }
        
        // 目前先发送 0xAA 0x55，后续再完善完整报文
        let packet = Data([0xAA, 0x55])
        connectedPeripheral?.writeValue(packet, for: characteristic, type: .withResponse)
        statusText = "已发送解锁指令"
    }
    
    // MARK: - 内部逻辑
    private func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        isScanning = false
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        statusText = "正在连接 \(peripheral.name ?? "设备")..."
    }
    
    private func resetState() {
        isConnected = false
        isAuthenticated = false
        authStep = 0
        phoneNonce = nil
        challengeCharacteristic = nil
        responseCharacteristic = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        connectedPeripheral = nil
        statusText = "已断开"
    }
    
    private func startAuthentication() {
        guard let characteristic = challengeCharacteristic else { return }
        
        // 生成 16 字节 phone_nonce
        var randomBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes) == errSecSuccess else {
            statusText = "生成随机数失败"
            return
        }
        
        phoneNonce = Data(randomBytes)
        
        // AES-128-ECB 加密后写入 Challenge 特征
        guard let encrypted = aesECBEncrypt(data: Data(randomBytes)) else {
            statusText = "加密失败"
            return
        }
        
        authStep = 1
        statusText = "正在进行双向认证..."
        connectedPeripheral?.writeValue(encrypted, for: characteristic, type: .withResponse)
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
        
        var outLength = Int(0)
        var outBytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        
        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),                 // 纯 ECB，不加 PKCS7
            aesKey,
            kCCKeySizeAES128,
            nil,
            Array(data),
            data.count,
            &outBytes,
            kCCBlockSizeAES128,
            &outLength
        )
        
        guard status == kCCSuccess else {
            print("CCCrypt error: \(status)")
            return nil
        }
        
        return Data(outBytes.prefix(outLength))
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusText = "蓝牙已开启，可以开始扫描"
        case .poweredOff:
            statusText = "蓝牙已关闭"
            resetState()
        case .unauthorized:
            statusText = "没有蓝牙权限"
        default:
            statusText = "蓝牙状态异常"
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, !name.isEmpty else { return }
        statusText = "发现设备: \(name)"
        connect(to: peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        statusText = "已连接，正在发现服务..."
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralKey)
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusText = "连接失败: \(error?.localizedDescription ?? "")"
        resetState()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        statusText = "连接断开"
        resetState()
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([
                challengeUUID,
                responseUUID,
                commandUUID,
                statusUUID
            ], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for char in characteristics {
            switch char.uuid {
            case challengeUUID:
                challengeCharacteristic = char
            case responseUUID:
                responseCharacteristic = char
                peripheral.setNotifyValue(true, for: char)   // 打开通知
            case commandUUID:
                commandCharacteristic = char
            case statusUUID:
                statusCharacteristic = char
            default:
                break
            }
        }
        
        // 关键特征和响应特征都准备好后开始认证
        if challengeCharacteristic != nil && responseCharacteristic != nil {
            startAuthentication()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        // 只处理 Response 特征的数据
        guard characteristic.uuid == responseUUID else { return }
        
        if authStep == 1 {
            // 期望收到至少 32 字节：
            // 前16字节 = AES-128-ECB(phone_nonce)
            // 后16字节 = module_nonce（明文）
            guard data.count >= 32 else {
                statusText = "认证数据包长度错误 (\(data.count))"
                return
            }
            
            let encryptedPhoneNonce = data.prefix(16)
            
            guard let decrypted = aesECBDecrypt(data: Data(encryptedPhoneNonce)),
                  decrypted == phoneNonce else {
                statusText = "认证失败（随机数不匹配）"
                return
            }
            
            // 认证成功
            authStep = 2
            isAuthenticated = true
            statusText = "认证完成"
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            statusText = "写入失败: \(error.localizedDescription)"
        }
    }
}
