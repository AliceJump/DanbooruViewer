package com.alicejump.danbooru_viewer

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.view.View
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.alicejump.danbooru_viewer/external_media"
        ).setMethodCallHandler { call, result ->
            if (call.method != "openFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val mimeType = call.argument<String>("mimeType")
            if (path.isNullOrBlank() || mimeType.isNullOrBlank()) {
                result.error("INVALID_ARGUMENTS", "path and mimeType are required", null)
                return@setMethodCallHandler
            }
            try {
                val file = File(path)
                if (!file.isFile || !file.canRead()) {
                    result.error("FILE_UNAVAILABLE", "Cached media is not readable", null)
                    return@setMethodCallHandler
                }
                val uri = FileProvider.getUriForFile(this, "$packageName.provider", file)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeType)
                    clipData = ClipData.newRawUri("Danbooru media", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivity(intent)
                result.success(true)
            } catch (_: ActivityNotFoundException) {
                result.success(false)
            } catch (_: Exception) {
                result.error("OPEN_FAILED", "Unable to open cached media", null)
            }
        }
    }

    private fun startDrag(path: String, type: String): Boolean {
        return try {
            val view = window.decorView.findViewById<View>(android.R.id.content)
                ?: window.decorView
            DragHelper.startImageDrag(view, path, type)
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun mimeTypeToType(mimeType: String): String {
        return if (mimeType.startsWith("video/")) "video" else "image"
    }
}
