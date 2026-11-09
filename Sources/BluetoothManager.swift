import Foundation
import CoreBluetooth
import CryptoKit
import Combine

class BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - 公开状态（界面用）
    @Published var statusText: String = "未连接"
    @Published var isConnected: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var isScanning: Bool = false
    
    // MARK: - 私有属性
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    
    // 记住上次连接的设备
    private let lastPeripheralKey = "LastConnectedPeripheralUUID"
    
    // ====== 需要根据你的实际蓝牙模块修改的地方 ======
    // 服务 UUID（示例，请改成你模块的）
    private let serviceUUID = CBUUID(string: "FFE0")
    // 写特征
    private let writeCharUUID = CBUUID(string: "FFE1")
    // 通知特征
    private let notifyCharUUID = CBUUID(string: "FFE2")
    
    // AES-128 密钥（16字节），正式使用请改成你自己的密钥！
    private let aesKey = "0123456789ABCDEF".data(using: .utf8)!   // 仅示例
    // =================================================
    
    private var authStep = 0          // 0=未开始 1=已发手机随机数 2=已完成
    private var phoneRandom: Data?
    
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
        
        isScanning = true
        statusText = "正在扫描..."
        isAuthenticated = false
        
        // 先尝试自动重连上次的设备
        if let uuidString = UserDefaults.standard.string(forKey: lastPeripheralKey),
           let uuid = UUID(uuidString: uuidString) {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = known.first {
                statusText = "尝试自动重连..."
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
        guard isAuthenticated, let characteristic = writeCharacteristic else {
            statusText = "请先完成认证"
            return
        }
        
        // 目前只发 0xAA 0x55，后续再完善完整报文
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
        phoneRandom = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectedPeripheral = nil
        statusText = "已断开"
    }
    
    private func startAuthentication() {
        guard let characteristic = writeCharacteristic else { return }
        
        // 1. 手机生成 16 字节随机数
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        phoneRandom = Data(randomBytes)
        
        // 2. 用 AES-128 加密后发送
        if let encrypted = aesEncrypt(Data(randomBytes)) {
            authStep = 1
            statusText = "正在进行双向认证..."
            connectedPeripheral?.writeValue(encrypted, for: characteristic, type: .withResponse)
        } else {
            statusText = "加密失败"
        }
    }
    
    // 简单 AES-128 ECB 加密（演示用，正式建议用更安全的模式）
    private func aesEncrypt(_ data: Data) -> Data? {
        // 这里用 CryptoKit 的 AES.GCM 做示例。
        // 真实项目中请根据蓝牙模块实际使用的 AES 模式（ECB/CBC）调整。
        do {
            let key = SymmetricKey(data: aesKey)
            let sealed = try AES.GCM.seal(data, using: key)
            return sealed.combined
        } catch {
            print("加密错误: \(error)")
            return nil
        }
    }
    
    private func aesDecrypt(_ data: Data) -> Data? {
        do {
            let key = SymmetricKey(data: aesKey)
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key)
        } catch {
            print("解密错误: \(error)")
            return nil
        }
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
        // 简单过滤：有名字的设备
        guard let name = peripheral.name, !name.isEmpty else { return }
        
        statusText = "发现设备: \(name)"
        connect(to: peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        statusText = "已连接，正在发现服务..."
        
        // 记住这个设备，下次自动重连
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
        
        // 可选：断开后自动重新扫描
        // startScan()
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        
        for service in services {
            peripheral.discoverCharacteristics([writeCharUUID, notifyCharUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for char in characteristics {
            if char.uuid == writeCharUUID {
                writeCharacteristic = char
            }
            if char.uuid == notifyCharUUID {
                notifyCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
        
        // 特征都找到后开始认证
        if writeCharacteristic != nil && notifyCharacteristic != nil {
            startAuthentication()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        // 认证阶段
        if authStep == 1 {
            // 收到模块返回的加密随机数
            if let decrypted = aesDecrypt(data) {
                // 这里简单认为解密成功就认证通过
                // 真实项目需要验证随机数内容是否符合预期
                authStep = 2
                isAuthenticated = true
                statusText = "认证完成"
            } else {
                statusText = "认证失败（解密错误）"
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            statusText = "写入失败: \(error.localizedDescription)"
        }
    }
}
