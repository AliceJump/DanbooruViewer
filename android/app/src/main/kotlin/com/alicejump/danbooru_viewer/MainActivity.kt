package com.alicejump.danbooru_viewer

import android.app.Activity
import android.content.ClipData
import android.os.Build
import android.view.View
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.danbooru_viewer/drag_drop"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startDragDrop" -> {
                    val imagePath: String? = call.argument("imagePath")
                    val mimeType: String? = call.argument("mimeType")
                    
                    if (imagePath != null && mimeType != null) {
                        val success = startDragDrop(imagePath, mimeType)
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENTS", "imagePath and mimeType are required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startDragDrop(imagePath: String, mimeType: String): Boolean {
        return try {
            val file = File(imagePath)
            if (!file.exists()) {
                return false
            }

            // 获取当前焦点视图
            val view = window.decorView.findViewById<View>(android.R.id.content)
                ?: window.decorView

            // 获取文件 URI
            val uri = FileProvider.getUriForFile(
                this,
                "${packageName}.provider",
                file
            )

            // 设置拖拽数据
            val mimeTypes = arrayOf(mimeType)
            val dragItem = ClipData.Item(uri)
            val clipData = ClipData("Image from DanbooruViewer", mimeTypes, dragItem)

            // 创建拖拽阴影
            val dragShadowBuilder = View.DragShadowBuilder(view)

            // 启动拖拽
            val dragFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ
            } else {
                View.DRAG_FLAG_GLOBAL
            }

            ViewCompat.startDragAndDrop(
                view,
                clipData,
                dragShadowBuilder,
                null,
                dragFlags
            )

            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
