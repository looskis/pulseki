import Foundation
import IOKit

/// GPU utilisation and memory from the IOAccelerator PerformanceStatistics
/// dictionary. Works on Apple silicon (AGXAccelerator*) and Intel/AMD
/// accelerators; the exact statistic keys vary by driver so each is optional.
final class GPUCollector: Collector {
    let name = "gpu"

    func collect() throws -> [MetricFamily] {
        let accelerators = IORegistry.services(matching: "IOAccelerator")
        defer { IORegistry.release(accelerators) }

        var count = MetricFamily(name: "macos_gpus", help: "Number of GPUs (IOAccelerator services).", type: .gauge)
        count.add(Double(accelerators.count))
        var info = MetricFamily(name: "macos_gpu_info", help: "GPU model and driver class.", type: .gauge)
        var cores = MetricFamily(name: "macos_gpu_cores", help: "GPU core count.", type: .gauge)
        var device = MetricFamily(name: "macos_gpu_device_utilization_ratio", help: "Overall GPU utilisation, 0 to 1.", type: .gauge)
        var renderer = MetricFamily(name: "macos_gpu_renderer_utilization_ratio", help: "GPU renderer utilisation, 0 to 1.", type: .gauge)
        var tiler = MetricFamily(name: "macos_gpu_tiler_utilization_ratio", help: "GPU tiler utilisation, 0 to 1.", type: .gauge)
        var inUse = MetricFamily(name: "macos_gpu_memory_in_use_bytes", help: "System memory currently in use by the GPU.", type: .gauge)
        var allocated = MetricFamily(name: "macos_gpu_memory_allocated_bytes", help: "System memory allocated to the GPU.", type: .gauge)
        var driverInUse = MetricFamily(name: "macos_gpu_memory_driver_in_use_bytes", help: "System memory in use by the GPU driver.", type: .gauge)
        var recoveries = MetricFamily(name: "macos_gpu_recoveries_total", help: "GPU driver recoveries (resets) since boot.", type: .counter)

        for (index, accelerator) in accelerators.enumerated() {
            let props = IORegistry.properties(of: accelerator)
            let gpu = String(index)
            let labels = [("gpu", gpu)]
            let className = IORegistry.className(of: accelerator)
            var model = IORegistry.string(props["model"])
            if model == nil, let parent = IORegistry.parent(of: accelerator) {
                model = IORegistry.string(IORegistry.properties(of: parent)["model"])
                IOObjectRelease(parent)
            }
            info.add(1, [("gpu", gpu), ("model", model ?? "unknown"), ("class", className)])
            if let v = IORegistry.number(props["gpu-core-count"]) { cores.add(v, labels) }

            let stats = props["PerformanceStatistics"] as? [String: Any] ?? [:]
            func put(_ key: String, into family: inout MetricFamily, scale: Double = 1) {
                if let v = IORegistry.number(stats[key]) { family.add(v * scale, labels) }
            }
            put("Device Utilization %", into: &device, scale: 0.01)
            put("Renderer Utilization %", into: &renderer, scale: 0.01)
            put("Tiler Utilization %", into: &tiler, scale: 0.01)
            put("In use system memory", into: &inUse)
            put("Alloc system memory", into: &allocated)
            put("In use system memory (driver)", into: &driverInUse)
            put("recoveryCount", into: &recoveries)
        }
        return [count, info, cores, device, renderer, tiler, inUse, allocated, driverInUse, recoveries]
    }
}
