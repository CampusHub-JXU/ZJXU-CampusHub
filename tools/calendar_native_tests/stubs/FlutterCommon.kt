package io.flutter.plugin.common

interface BinaryMessenger {
    class TaskQueueOptions {
        var serial: Boolean = false
            private set
        fun setIsSerial(value: Boolean): TaskQueueOptions = apply { serial = value }
    }
    interface TaskQueue
    fun makeBackgroundTaskQueue(options: TaskQueueOptions): TaskQueue
    fun setTaskQueue(queue: TaskQueue)
}

class StandardMethodCodec private constructor() {
    companion object { val INSTANCE = StandardMethodCodec() }
}

class MethodCall(val method: String, private val arguments: Map<String, Any?> = emptyMap()) {
    @Suppress("UNCHECKED_CAST")
    fun <T> argument(key: String): T? = arguments[key] as T?
}

class MethodChannel(
    messenger: BinaryMessenger,
    val name: String,
    val codec: StandardMethodCodec,
    val taskQueue: BinaryMessenger.TaskQueue,
) {
    interface Result {
        fun success(result: Any?)
        fun error(code: String, message: String?, details: Any?)
        fun notImplemented()
    }
    fun interface MethodCallHandler { fun onMethodCall(call: MethodCall, result: Result) }
    private var handler: MethodCallHandler? = null
    init { (messenger as FakeBinaryMessenger).channel = this }
    fun setMethodCallHandler(handler: MethodCallHandler?) { this.handler = handler }
    fun invoke(call: MethodCall, result: Result) {
        (taskQueue as FakeTaskQueue).execute { handler!!.onMethodCall(call, result) }
    }
}

class FakeTaskQueue(val serial: Boolean) : BinaryMessenger.TaskQueue {
    private val executor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "flutter-calendar-queue").also { it.isDaemon = true }
    }
    fun execute(block: () -> Unit) { executor.execute(block) }
    fun close() { executor.shutdownNow() }
}

class FakeBinaryMessenger : BinaryMessenger {
    lateinit var channel: MethodChannel
    lateinit var queue: FakeTaskQueue
    override fun makeBackgroundTaskQueue(options: BinaryMessenger.TaskQueueOptions): BinaryMessenger.TaskQueue =
        FakeTaskQueue(options.serial).also { queue = it }
    override fun setTaskQueue(queue: BinaryMessenger.TaskQueue) {}
}
