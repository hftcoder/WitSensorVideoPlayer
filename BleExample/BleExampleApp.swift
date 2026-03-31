//
//  欢迎您使用维特智能蓝牙5.0示例程序
//  1.为了方便您使用，本程序只有这一个代码文件
//  2.本程序适用于维特智能蓝牙5.0倾角传感器
//  3.本程序将演示如何获得传感器的数据和控制传感器
//  4.如果您有疑问可以查看程序配套说明文档，或者咨询我们技术人员
//
//  Welcome to the Witte Smart Bluetooth 5.0 sample program
//  1. For your convenience, this program has only this code file
//  2. This program is suitable for Witte Smart Bluetooth 5.0 inclination sensor
//  3. This program will demonstrate how to obtain sensor data and control the sensor
//  4. If you have any questions, you can check the program supporting documentation, or consult our technical staff
//
//  Created by huangyajun on 2022/8/26.
//


import SwiftUI
import CoreBluetooth
import Combine
import WitSDK


// **********************************************************
// MARK: App主视图
// MARK: App main view
// **********************************************************
@main
struct AppMainView : App {
    // MARK: App上下文
    // MARK: App the context
    var appContext:AppContext = AppContext()
    
    // MARK: UI页面
    // MARK: UI Page
    var body: some Scene {
        WindowGroup {
            if (UIDevice.current.userInterfaceIdiom == .phone){
                VideoPlayerView(viewModel: appContext)
            } else {
                VideoPlayerView(viewModel: appContext)
            }
        }
    }
}


// **********************************************************
// MARK: App上下文
// MARK: App the context
// **********************************************************
class AppContext: ObservableObject ,IBluetoothEventObserver, IBwt901bleRecordObserver{
    
    // 获得蓝牙管理器
    // Get bluetooth manager
    var bluetoothManager:WitBluetoothManager = WitBluetoothManager.instance
    
    // 是否扫描设备中
    // Whether to scan the device
    @Published
    var enableScan = false
    
    // 蓝牙5.0传感器对象
    // Bluetooth 5.0 sensor object
    @Published
    var deviceList:[Bwt901ble] = [Bwt901ble]()
    
    // 已连接的设备
    // Connected device
    @Published
    var connectedDevice: Bwt901ble?
    
    // 传感器驱动的播放速率
    @Published
    var sensorPlaybackRate: Float = 1.0
    
    // EMA 平滑状态
    private var smoothedIntensity: Double = 0.0
    private let smoothingAlpha: Double = 0.25
    private let maxShakeIntensity: Double = 3.0
    
    // 要显示的设备数据
    // Device data to display
    @Published
    var deviceData:String = "未连接设备 device not connected"
    
    // Combine cancellables（用于 Timer）
    private var cancellables = Set<AnyCancellable>()
    
    init(){
        // 当前扫描状态
        // Current scan status
        self.enableScan = self.bluetoothManager.isScaning
        // 开启定时刷新
        startRefreshTimer()
    }
    
    // MARK: 开始扫描设备
    // MARK: Start scanning for devices
    func scanDevices() {
        print("开始扫描周围蓝牙设备 Start scanning for surrounding bluetooth devices")
        // 移除所有的设备，在这里会关闭所有设备并且从列表中移除
        // Remove all devices, here all devices are turned off and removed from the list
        removeAllDevice()
        // 注册蓝牙事件观察者
        // Registering a Bluetooth event observer
        self.bluetoothManager.registerEventObserver(observer: self)
        // 开启蓝牙扫描
        // Turn on bluetooth scanning
        self.bluetoothManager.startScan()
    }
    
    // MARK: 如果找到低功耗蓝牙传感器会调用这个方法
    // MARK: This method is called if a Bluetooth Low Energy sensor is found
    func onFoundBle(bluetoothBLE: BluetoothBLE?) {
        if isNotFound(bluetoothBLE) {
            print("\(String(describing: bluetoothBLE?.peripheral.name)) 找到一个蓝牙设备 found a bluetooth device")
            self.deviceList.append(Bwt901ble(bluetoothBLE: bluetoothBLE))
        }
    }
    
    // 判断设备还未找到
    // Judging that the device has not been found
    func isNotFound(_ bluetoothBLE: BluetoothBLE?) -> Bool{
        for device in deviceList {
            if device.mac == bluetoothBLE?.mac {
                return false
            }
        }
        return true
    }
    
    // MARK: 当连接成功时会在这里通知您
    // MARK: You will be notified here when the connection is successful
    func onConnected(bluetoothBLE: BluetoothBLE?) {
        print("\(String(describing: bluetoothBLE?.peripheral.name)) 连接成功")
        // 更新已连接设备
        if let bluetoothBLE = bluetoothBLE {
            for device in deviceList {
                if device.mac == bluetoothBLE.mac {
                    connectedDevice = device
                    break
                }
            }
        }
    }
    
    // MARK: 当连接失败时会在这里通知您
    // MARK: Notifies you here when the connection fails
    func onConnectionFailed(bluetoothBLE: BluetoothBLE?) {
        print("\(String(describing: bluetoothBLE?.peripheral.name)) 连接失败")
    }
    
    // MARK: 当连接断开时会在这里通知您
    // MARK: You will be notified here when the connection is lost
    func onDisconnected(bluetoothBLE: BluetoothBLE?) {
        print("\(String(describing: bluetoothBLE?.peripheral.name)) 连接断开")
        // 清除已连接设备
        if let bluetoothBLE = bluetoothBLE, connectedDevice?.mac == bluetoothBLE.mac {
            connectedDevice = nil
        }
    }
    
    // MARK: 停止扫描设备
    // MARK: Stop scanning for devices
    func stopScan(){
        // 删除蓝牙事件观察器
        self.bluetoothManager.removeEventObserver(observer: self)
        // 移除监听新找到的传感器
        self.bluetoothManager.stopScan()
    }
    
    // MARK: 打开设备
    // MARK: Turn on the device
    func openDevice(bwt901ble: Bwt901ble?){
        print("打开设备 MARK: Turn on the device")
        
        do {
            try bwt901ble?.openDevice()
            // 监听数据
            // Monitor data
            bwt901ble?.registerListenKeyUpdateObserver(obj: self)
        }
        catch{
            print("打开设备失败 Failed to open device")
        }
    }
    
    // MARK: 移除所有设备
    // MARK: Remove all devices
    func removeAllDevice(){
        for item in deviceList {
            closeDevice(bwt901ble: item)
            item.isOpen = false
        }
        deviceList.removeAll()
    }
    
    // MARK: 关闭设备
    // MARK: Turn off the device
    func closeDevice(bwt901ble: Bwt901ble?){
        print("关闭设备 Turn off the device")
        bwt901ble?.isOpen = false
        bwt901ble?.closeDevice()
        if connectedDevice?.mac == bwt901ble?.mac {
            connectedDevice = nil
        }
    }
    
    // MARK: 当需要记录传感器的数据时会在这里通知您
    // MARK: You will be notified here when data from the sensor needs to be recorded
    func onRecord(_ bwt901ble: Bwt901ble) {
        guard let axStr = bwt901ble.getDeviceData(WitSensorKey.AccX),
              let ayStr = bwt901ble.getDeviceData(WitSensorKey.AccY),
              let azStr = bwt901ble.getDeviceData(WitSensorKey.AccZ),
              let ax = Double(axStr),
              let ay = Double(ayStr),
              let az = Double(azStr) else {
            return
        }
        
        // 计算合成加速度并减去重力得到晃动强度
        let magnitude = sqrt(ax * ax + ay * ay + az * az)
        let rawIntensity = abs(magnitude - 1.0)
        
        // EMA 平滑
        smoothedIntensity = smoothingAlpha * rawIntensity + (1.0 - smoothingAlpha) * smoothedIntensity
        
        // 映射到 0.25x ~ 4.0x
        let clampedIntensity = min(smoothedIntensity, maxShakeIntensity)
        let rate = 0.25 + (clampedIntensity / maxShakeIntensity) * 3.75
        
        // 量化到 0.05 步长
        let quantized = Float(round(rate / 0.05) * 0.05)
        
        DispatchQueue.main.async {
            self.sensorPlaybackRate = quantized
        }
    }
    
    // MARK: 开启自动执行线程
    // MARK: 开启定时刷新（替代 Thread + sleep）
    func startRefreshTimer() {
        Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshDeviceData()
            }
            .store(in: &cancellables)
    }
    
    // MARK: 刷新视图，每 0.2 秒触发一次
    private func refreshDeviceData() {
        var tmpDeviceData = ""
        for device in deviceList {
            if device.isOpen {
                tmpDeviceData = "\(tmpDeviceData)\r\n\(getDeviceDataToString(device))"
            }
        }
        if !tmpDeviceData.isEmpty {
            deviceData = tmpDeviceData
        }
    }
    
    // MARK: 获得设备的数据，并且拼接为字符串
    // MARK: Get the data of the device and concatenate it into a string
    func getDeviceDataToString(_ device:Bwt901ble) -> String {
        var s = ""
        s  = "\(s)name:\(device.name ?? "")\r\n"
        s  = "\(s)mac:\(device.mac ?? "")\r\n"
        s  = "\(s)version:\(device.getDeviceData(WitSensorKey.VersionNumber) ?? "")\r\n"
        s  = "\(s)AX:\(device.getDeviceData(WitSensorKey.AccX) ?? "") g\r\n"
        s  = "\(s)AY:\(device.getDeviceData(WitSensorKey.AccY) ?? "") g\r\n"
        s  = "\(s)AZ:\(device.getDeviceData(WitSensorKey.AccZ) ?? "") g\r\n"
        s  = "\(s)GX:\(device.getDeviceData(WitSensorKey.GyroX) ?? "") °/s\r\n"
        s  = "\(s)GY:\(device.getDeviceData(WitSensorKey.GyroY) ?? "") °/s\r\n"
        s  = "\(s)GZ:\(device.getDeviceData(WitSensorKey.GyroZ) ?? "") °/s\r\n"
        s  = "\(s)AngX:\(device.getDeviceData(WitSensorKey.AngleX) ?? "") °\r\n"
        s  = "\(s)AngY:\(device.getDeviceData(WitSensorKey.AngleY) ?? "") °\r\n"
        s  = "\(s)AngZ:\(device.getDeviceData(WitSensorKey.AngleZ) ?? "") °\r\n"
        s  = "\(s)HX:\(device.getDeviceData(WitSensorKey.MagX) ?? "") μt\r\n"
        s  = "\(s)HY:\(device.getDeviceData(WitSensorKey.MagY) ?? "") μt\r\n"
        s  = "\(s)HZ:\(device.getDeviceData(WitSensorKey.MagZ) ?? "") μt\r\n"
        s  = "\(s)Electric:\(device.getDeviceData(WitSensorKey.ElectricQuantityPercentage) ?? "") %\r\n"
        s  = "\(s)Temp:\(device.getDeviceData(WitSensorKey.Temperature) ?? "") °C\r\n"
        return s
    }
    
    // MARK: 加计校准
    // MARK: Addition calibration
    func appliedCalibration(){
        for device in deviceList {
            
            do {
                // 解锁寄存器
                // Unlock register
                try device.unlockReg()
                // 加计校准
                // Addition calibration
                try device.appliedCalibration()
                // 保存
                // save
                try device.saveReg()
                
            }catch{
                print("设置失败 Set failed")
            }
        }
    }
    
    // MARK: 开始磁场校准
    // MARK: Start magnetic field calibration
    func startFieldCalibration(){
        for device in deviceList {
            do {
                // 解锁寄存器
                // Unlock register
                try device.unlockReg()
                // 开始磁场校准
                // Start magnetic field calibration
                try device.startFieldCalibration()
                // 保存
                // save
                try device.saveReg()
            }catch{
                print("设置失败 Set failed")
            }
        }
    }
    
    // MARK: 结束磁场校准
    // MARK: End magnetic field calibration
    func endFieldCalibration(){
        for device in deviceList {
            do {
                // 解锁寄存器
                // Unlock register
                try device.unlockReg()
                // 结束磁场校准
                // End magnetic field calibration
                try device.endFieldCalibration()
                // 保存
                // save
                try device.saveReg()
            }catch{
                print("设置失败 Set failed")
            }
        }
    }
    
    // MARK: 读取03寄存器
    // MARK: Read the 03 register
    func readReg03(){
        for device in deviceList {
            do {
                // 读取03寄存器，等待200ms，如果没读到可以把读取时间延长或多读几次
                // Read the 03 register and wait for 200ms. If it is not read out, you can extend the reading time or read it several times
                try device.readRge([0xff ,0xaa, 0x27, 0x03, 0x00], 200, {
                    let reg03value = device.getDeviceData("03")
                    // 输出结果到控制台
                    // Output the result to the console
                    print("\(String(describing: device.mac)) reg03value: \(String(describing: reg03value))")
                })
            }catch{
                print("设置失败 Set failed")
            }
        }
    }
    
    // MARK: 设置50hz回传
    // MARK: Set 50hz postback
    func setBackRate50hz(){
        for device in deviceList {
            do {
                // 解锁寄存器
                // unlock register
                try device.unlockReg()
                // 设置50hz回传,并等待10ms
                // Set 50hz postback and wait 10ms
                try device.writeRge([0xff ,0xaa, 0x03, 0x08, 0x00], 10)
                // 保存
                // save
                try device.saveReg()
            }catch{
                print("设置失败 Set failed")
            }
        }
    }
    
    // MARK: 设置10hz回传
    // MARK: Set 10hz postback
    func setBackRate10hz(){
        for device in deviceList {
            do {
                // 解锁寄存器
                // unlock register
                try device.unlockReg()
                // 设置10hz回传,并等待10ms
                // Set 10hz postback and wait 10ms
                try device.writeRge([0xff ,0xaa, 0x03, 0x06, 0x00], 100)
                // 保存
                // save
                try device.saveReg()
            }catch{
                print("设置失败 Set failed")
            }
        }
    }
}
