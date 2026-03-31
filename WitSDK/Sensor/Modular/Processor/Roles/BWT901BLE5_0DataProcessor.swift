//
//  蓝牙5.0数据处理器
//
//  Created by huangyajun on 2022/9/1.
//

import Foundation


class BWT901BLE5_0DataProcessor : IDataProcessor {
    
    // 定时器（替代 Thread + sleep 轮询）
    var pollingTimer: Timer?
    
    // 设备模型
    var deviceModel: DeviceModel?
    
    // 轮询计数器
    private var tickCount: Int = 0
    
    // 轮询间隔（秒）
    private let pollInterval: TimeInterval = 0.5
    
    // MARK: 传感器打开时
    func onOpen(deviceModel: DeviceModel) {
        self.deviceModel = deviceModel
        tickCount = 0
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollRegisters()
        }
        pollingTimer?.tolerance = 0.1
    }
    
    // MARK: 传感器关闭时
    func onClose() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    // MARK: 轮询寄存器（每 pollInterval 秒触发一次）
    private func pollRegisters() {
        guard let deviceModel = deviceModel else { return }
        
        do {
            // 磁场类型（只读一次）
            let magType: String? = deviceModel.getDeviceData("72")
            if StringUtils.IsNullOrEmpty(magType) {
                try sendProtocolData(data: [0xff, 0xaa, 0x27, 0x72, 0x00])
            }
            
            // 版本号（只读一次）
            let reg2e: String? = deviceModel.getDeviceData("2E")
            let reg2f: String? = deviceModel.getDeviceData("2F")
            if StringUtils.IsNullOrEmpty(reg2e) || StringUtils.IsNullOrEmpty(reg2f) {
                try sendProtocolData(data: [0xff, 0xaa, 0x27, 0x2E, 0x00])
            }
            
            // 高频数据（每轮都读）
            try sendProtocolData(data: [0xff, 0xaa, 0x27, 0x3a, 0x00]) // 磁场
            try sendProtocolData(data: [0xff, 0xaa, 0x27, 0x51, 0x00]) // 四元数
            
            // 低频数据（每50轮读一次，前5轮也读）
            tickCount += 1
            if tickCount % 50 == 0 || tickCount <= 5 {
                try sendProtocolData(data: [0xff, 0xaa, 0x27, 0x64, 0x00]) // 电量
                try sendProtocolData(data: [0xff, 0xaa, 0x27, 0x40, 0x00]) // 温度
            }
        } catch {
            print("BWT901BLE5_0DataProcessor: 轮询异常")
        }
    }
    
    // MARK: 发送协议数据（BLE 异步，无需 sleep 等待）
    private func sendProtocolData(data: [UInt8]) throws {
        try deviceModel?.sendProtocolData(data: data)
    }
    
    // MARK: 传感器更新时（被动触发，由 ProtocolResolver 调用）
    func onUpdate(deviceModel:DeviceModel) {
        
        // 加速度
        let regAx:String? = deviceModel.getDeviceData("61_0");
        let regAy:String? = deviceModel.getDeviceData("61_1");
        let regAz:String? = deviceModel.getDeviceData("61_2");
        // 角速度
        let regWx:String? = deviceModel.getDeviceData("61_3");
        let regWy:String? = deviceModel.getDeviceData("61_4");
        let regWz:String? = deviceModel.getDeviceData("61_5");
        // 角度
        let regAngleX:String? = deviceModel.getDeviceData("61_6");
        let regAngleY:String? = deviceModel.getDeviceData("61_7");
        let regAngleZ:String? = deviceModel.getDeviceData("61_8");
        
        // 四元数
        let regQ1:String? = deviceModel.getDeviceData("51");
        let regQ2:String? = deviceModel.getDeviceData("52");
        let regQ3:String? = deviceModel.getDeviceData("53");
        let regQ4:String? = deviceModel.getDeviceData("54");
        // 温度和电量
        let regTemperature:String? = deviceModel.getDeviceData("40");
        let regPower:String? = deviceModel.getDeviceData("64");
        
        
        // 版本号
        let reg2e:String? = deviceModel.getDeviceData("2E");// 版本号
        let reg2f:String? = deviceModel.getDeviceData("2F");// 版本号
        
   
        // 如果有版本号
        if let reg2eVal = reg2e, let reg2fVal = reg2f,
           let v2e = Double(reg2eVal), let v2f = Double(reg2fVal) {
            let sum = Int32(Int16(v2f)) << 16 | Int32(Int16(v2e))
            var sbinary = String(UInt32(bitPattern: sum), radix: 2)
            sbinary = StringUtils.padLeft(sbinary, 32, "0")
            if sbinary.first == "1" {
                let part1 = String(UInt32(StringUtils.subString(sbinary, 4, 7), radix: 2) ?? 0)
                let part2 = String(UInt32(StringUtils.subString(sbinary, 18, 6), radix: 2) ?? 0)
                let part3 = String(UInt32(StringUtils.subString(sbinary, 24, 8), radix: 2) ?? 0)
                deviceModel.setDeviceData(WitSensorKey.VersionNumber, "\(part1).\(part2).\(part3)")
            } else {
                deviceModel.setDeviceData(WitSensorKey.VersionNumber, reg2eVal)
            }
        }
        
        // 加速度解算
        if let reg = regAx, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.AccX, String(format: "%.3f", v / 32768 * 16));
        }
        if let reg = regAy, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.AccY, String(format: "%.3f", v / 32768 * 16));
        }
        if let reg = regAz, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.AccZ, String(format: "%.3f", v / 32768 * 16));
        }
        
        // 角速度解算
        if let reg = regWx, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.GyroX, String(format: "%.3f", v / 32768 * 2000));
        }
        if let reg = regWy, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.GyroY, String(format: "%.3f", v / 32768 * 2000));
        }
        if let reg = regWz, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.GyroZ, String(format: "%.3f", v / 32768 * 2000));
        }
        
        // 角度
        if let reg = regAngleX, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.AngleX, String(format: "%.3f", v / 32768 * 180));
        }
        if let reg = regAngleY, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.AngleY, String(format: "%.3f", v / 32768 * 180));
        }
        if let reg = regAngleZ, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.AngleZ, String(format: "%.3f", v / 32768 * 180));
        }
        
        // 磁场
        let regHX:String? = deviceModel.getDeviceData("3A");
        let regHY:String? = deviceModel.getDeviceData("3B");
        let regHZ:String? = deviceModel.getDeviceData("3C");
        // 磁场类型
        let magTypeStr: String? = deviceModel.getDeviceData("72");
        if let regHX = regHX, let regHY = regHY, let regHZ = regHZ, let magTypeStr = magTypeStr,
           let vx = Double(regHX), let vy = Double(regHY), let vz = Double(regHZ),
           let magTypeInt = Int(magTypeStr, radix: 10) {
            let type: Int16 = Int16(magTypeInt)
            deviceModel.setDeviceData(WitSensorKey.MagX, String(DipSensorMagHelper.GetMagToUt(type, vx)));
            deviceModel.setDeviceData(WitSensorKey.MagY, String(DipSensorMagHelper.GetMagToUt(type, vy)));
            deviceModel.setDeviceData(WitSensorKey.MagZ, String(DipSensorMagHelper.GetMagToUt(type, vz)));
        }
        
        // 温度
        if let reg = regTemperature, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.Temperature, String(format: "%.2f", v / 100));
        }
        
        // 电量
        if let reg = regPower, let regPowerValue = Int(reg) {
            let eqPercent = getEqPercent(Float(regPowerValue) / 100.0)
            deviceModel.setDeviceData(WitSensorKey.ElectricQuantityPercentage, String(eqPercent))
            deviceModel.setDeviceData(WitSensorKey.ElectricQuantity, String(regPowerValue))
        }
        
        // 四元数
        if let reg = regQ1, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.Q0, String(format: "%.5f", v / 32768));
        }
        if let reg = regQ2, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.Q1, String(format: "%.5f", v / 32768));
        }
        if let reg = regQ3, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.Q2, String(format: "%.5f", v / 32768));
        }
        if let reg = regQ4, let v = Double(reg) {
            deviceModel.setDeviceData(WitSensorKey.Q3, String(format: "%.5f", v / 32768));
        }
        
    }
    
    // 获得电流值
    func getEqPercent(_ eq:Float) -> Int {
        var p:Int = 0;
        if(eq >= 3.96){
            p = 100
        }
        else if(eq >= 3.93 && eq < 3.96){
            p = 90
        }
        else if(eq >= 3.87 && eq < 3.93){
            p = 75
        }
        else if(eq >= 3.82 && eq < 3.87){
            p = 60
        }
        else if(eq >= 3.79 && eq < 3.82){
            p = 50
        }
        else if(eq >= 3.77 && eq < 3.79){
            p = 40
        }
        else if(eq >= 3.73 && eq < 3.77){
            p = 30
        }
        else if(eq >= 3.70 && eq < 3.73){
            p = 20
        }
        else if(eq >= 3.68 && eq < 3.70){
            p = 15
        }
        else if(eq >= 3.50 && eq < 3.68){
            p = 10
        }
        else if(eq >= 3.40 && eq < 3.50){
            p = 5
        }
        else if(eq < 3.40){
            p = 0
        }
        return p;
    }
    
    // 匹配百分比
    func Interp(_ a:Float,_ x:[Float],_ y:[Float]) -> Float {
        var v:Float = 0;
        let L:Int = x.count;
        if (a < x[0]) { v = y[0]}
        else if (a > x[L - 1]) {v = y[L - 1]}
        else {
            var i:Int = 0
            while (i < y.count - 1) {
                if (a > x[i + 1]) { i = i+1; continue; }
                v = y[i] + (a - x[i]) / (x[i + 1] - x[i]) * (y[i + 1] - y[i]);
                break;
            }
        }
        return v;
    }
    
    func ReadMagType( deviceModel:DeviceModel) {
        // 读取72磁场类型寄存器,后面解析磁场的时候要用到
        //deviceModel.sendProtocolData(new byte[]{(byte) 0xff, (byte) 0xaa, 0x27, 0x72, 0x00});
    }
}




