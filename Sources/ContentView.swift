import SwiftUI

struct ContentView: View {
    @StateObject private var bluetooth = BluetoothManager()
    @State private var showingDiagnostics = false
    
    var body: some View {
        VStack(spacing: 30) {
            
            // 标题
            Text("AstraKey")
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
                    Label("模块信号强度", systemImage: "antenna.radiowaves.left.and.right")
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
                    Label("正在标定，请保持手机在 1 米处静止 3 秒", systemImage: "ruler")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                } else if bluetooth.isCalibrationBusy {
                    Label("正在等待标定保存结果", systemImage: "hourglass")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                } else if let result = bluetooth.calibrationResultText {
                    Label(result, systemImage: bluetooth.calibrationSucceeded ?
                        "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundColor(bluetooth.calibrationSucceeded ? .green : .red)
                        .multilineTextAlignment(.center)
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
                    bluetooth.calibrateAtOneMeter()
                }) {
                    HStack{
                        if bluetooth.isCalibrationBusy {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(bluetooth.isCalibrating ? "正在标定..." :
                             (bluetooth.isCalibrationBusy ? "等待保存结果..." : "一米标定"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(bluetooth.isAuthenticated && !bluetooth.isCalibrationBusy ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!bluetooth.isAuthenticated || bluetooth.isCalibrationBusy)
                
                // 一键解锁按钮
                Button(action: {
                    bluetooth.unlock()
                }) {
                    HStack{
                        if bluetooth.isWaitingForProximity {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(bluetooth.isWaitingForProximity ? "正在确认距离..." : "一键解锁")
                    }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(bluetooth.isAuthenticated && !bluetooth.isCalibrationBusy ? Color.green : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(!bluetooth.isAuthenticated || bluetooth.isCalibrationBusy || bluetooth.isWaitingForProximity)
            }

            HStack(spacing: 24) {
                Button {
                    showingDiagnostics = true
                } label: {
                    Label("连接诊断", systemImage: "timer")
                    .font(.subheadline)
                }
                if bluetooth.autoConnectEnabled && !bluetooth.isConnected {
                    Button {
                        bluetooth.rescan()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                    }
                }
            }
            
            Spacer()
            
            Text("仅支持 iOS 16+")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .sheet(isPresented: $showingDiagnostics) {
            TimingDiagnosticsView(bluetooth: bluetooth)
        }
    }
}
private struct TimingDiagnosticsView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View{
        NavigationStack{
            Group {
                if bluetooth.timingLogs.isEmpty {
                    VStack(spacing: 12){
                        Image(systemName: "timer")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("暂无计时日志")
                            .foregroundColor(.secondary)
                        Text("开始连接后，这里会显示各阶段累计耗时")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(bluetooth.timingLogs.indices, id: \.self) {index in
                        Text(bluetooth.timingLogs[index])
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("连接诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("清空") {
                        bluetooth.clearTimingLogs()
                    }
                    .disabled(bluetooth.timingLogs.isEmpty)
                }
            }
        }
    }
}
#Preview {
    ContentView()
}
