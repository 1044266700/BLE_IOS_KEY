import SwiftUI

struct ContentView: View {
    @StateObject private var bluetooth = BluetoothManager()
    @State private var calibrationSessionObserved = false
    
    var body: some View {
        VStack(spacing: 30) {
            
            // 标题
            Text("蓝牙钥匙")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // 状态卡片
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(bluetooth.isConnected ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                    Text(bluetooth.isConnected ? "已连接" : "未连接")
                }
                
                Text(bluetooth.statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text(bluetooth.autoConnectEnabled ? "后台自动连接：开启" : "后台自动连接：已暂停")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(bluetooth.backgroundBluetoothEnabled ? "蓝牙后台模式：已启用" : "蓝牙后台模式：未启用")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    Label("模块信号强度", systemImage: "antenna.radiowaves.left.adn.right")
                    Spacer()
                    if let rssi = bluetooth.filteredRSSI {
                        Text("\(rssi) dBm")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    } else {
                        Text("--")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
                
                if let batteryLevel = bluetooth.batteryLevel {
                    VStack(spacing: 6) {
                        HStack{
                            Label("电池电量", systemImage: "battery.100")
                            Spacer()
                            Text("\(batteryLevel)%")
                                .fontWeight(.semibold)
                        }
                        ProgressView(value: Double(batteryLevel), total: 100)
                            .tint(.green)
                    }
                    .padding(.top, 4)
                }
                
                if bluetooth.isAuthenticated {
                    Text("认证完成")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                        .padding(.top, 8)
                }
                if bluetooth.isCalibrating {
                    Label("正在标定，请保持手机在1米处静止3秒", systemImage: "ruler")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                } else if calibrationSessionObserved && bluetooth.isAuthenticated {
                    Label("标定完成，1米阈值已更新", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
            .cornerRadius(16)
            
            // 按钮区域
            VStack(spacing: 16) {
                Button(action: {
                    if bluetooth.isConnected || bluetooth.autoConnectEnabled {
                        bluetooth.disconnect()
                    } else {
                        bluetooth.startScan()
                    }
                }) {
                    Text(bluetooth.isConnected ? "断开并暂停自动连接" : 
                            (bluetooth.autoConnectEnabled ? "暂停自动连接" : "开启自动连接"))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(bluetooth.autoConnectEnabled ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                // 一米标定按钮
                Button(action: {
                    calibrationSessionObserved = false
                    bluetooth.calibrateAtOneMeter()
                }) {
                    HStack{
                        if bluetooth.isCalibrating {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(bluetooth.isCalibrating ? "正在标定..." : "一米标定")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(bluetooth.isAuthenticated && !bluetooth.isCalibrating ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!bluetooth.isAuthenticated || bluetooth.isCalibrating)
                
                // 一键解锁按钮
                Button(action: {
                    bluetooth.unlock()
                }) {
                    Text("一键解锁")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(bluetooth.isAuthenticated ? Color.green : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(!bluetooth.isAuthenticated)
            }
            
            Spacer()
            
            Text("仅支持 iOS 16+")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .onChange(of: bluetooth.isCalibrating) { isCalibrating in
            if isCalibrating{
                calibrationSessionObserved = true
            }
        }
        .onChange(of: bluetooth.isConnected) { isConnected in
            if !isConnected{
                calibrationSessionObserved = false
            }
        }
    }
}

#Preview {
    ContentView()
}
