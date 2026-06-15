package com.alicejump.danbooru_viewer

import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.alicejump.danbooru_viewer/drag"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startDrag" -> {
                    val path: String? = call.argument("path")
                    val type: String? = call.argument("type")

                    if (path != null && type != null) {
                        val success = startDrag(path, type)
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENTS", "path and type are required", null)
                    }
                }
                "startDragDrop" -> {
                    val imagePath: String? = call.argument("imagePath")
                    val mimeType: String? = call.argument("mimeType")

                    if (imagePath != null && mimeType != null) {
                        val success = startDrag(imagePath, mimeTypeToType(mimeType))
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENTS", "imagePath and mimeType are required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startDrag(path: String, type: String): Boolean {
        return try {
            val view = window.decorView.findViewById<View>(android.R.id.content)
                ?: window.decorView
            DragHelper.startImageDrag(view, path, type)

            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun mimeTypeToType(mimeType: String): String {
        return if (mimeType.startsWith("video/")) "video" else "image"
    }
}
