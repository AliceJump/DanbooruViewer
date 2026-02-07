package com.alicejump.danbooru_viewer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.alicejump.danbooru_viewer/drag"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            if (call.method == "startDrag") {

                val path = call.argument<String>("path")
                val type = call.argument<String>("type") ?: "image"

                if (path == null) {
                    result.error("INVALID", "path is null", null)
                    return@setMethodCallHandler
                }

                val rootView = window.decorView.rootView

                DragHelper.startImageDrag(rootView, path, type)

                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
