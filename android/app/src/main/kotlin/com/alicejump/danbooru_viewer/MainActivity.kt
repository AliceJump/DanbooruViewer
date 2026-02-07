package com.alicejump.danbooru_viewer

import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.graphics.Canvas
import android.graphics.Point
import android.graphics.drawable.Drawable
import android.view.View
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URL
import kotlin.math.max

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.alicejump.danbooru_viewer/drag"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "startDrag") {
                val url = call.argument<String>("url")
                if (url != null) {
                    startDrag(url)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "URL cannot be null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private class ImageDragShadowBuilder(context: Context, private val imageFile: File) : View.DragShadowBuilder() {
        private val shadow = Drawable.createFromPath(imageFile.absolutePath)

        private val density = context.resources.displayMetrics.density
        private val MAX_LONGEST_EDGE_DP = 120
        private val MIN_LONGEST_EDGE_DP = 50

        private fun dpToPx(dp: Int): Int {
            return (dp * density).toInt()
        }

        override fun onProvideShadowMetrics(outShadowSize: Point, outShadowTouchPoint: Point) {
            val maxEdgePx = dpToPx(MAX_LONGEST_EDGE_DP)
            val minEdgePx = dpToPx(MIN_LONGEST_EDGE_DP)

            val originalWidth = shadow?.intrinsicWidth ?: minEdgePx
            val originalHeight = shadow?.intrinsicHeight ?: minEdgePx

            val ratio = if (originalHeight > 0) originalWidth.toFloat() / originalHeight.toFloat() else 1.0f
            val longestEdge = max(originalWidth, originalHeight)

            val (width, height) = when {
                longestEdge > maxEdgePx -> { // Scale down
                    if (originalWidth > originalHeight) {
                        Pair(maxEdgePx, (maxEdgePx / ratio).toInt())
                    } else {
                        Pair((maxEdgePx * ratio).toInt(), maxEdgePx)
                    }
                }
                longestEdge < minEdgePx -> { // Scale up
                    if (originalWidth > originalHeight) {
                        Pair(minEdgePx, (minEdgePx / ratio).toInt())
                    } else {
                        Pair((minEdgePx * ratio).toInt(), minEdgePx)
                    }
                }
                else -> Pair(originalWidth, originalHeight) // Use original
            }

            val finalWidth = if (width > 0) width else minEdgePx
            val finalHeight = if (height > 0) height else minEdgePx

            shadow?.setBounds(0, 0, finalWidth, finalHeight)
            outShadowSize.set(finalWidth, finalHeight)
            outShadowTouchPoint.set(finalWidth / 2, finalHeight / 2)
        }

        override fun onDrawShadow(canvas: Canvas) {
            shadow?.draw(canvas)
        }
    }

    private fun startDrag(url: String) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val tempFile = File(cacheDir, url.substringAfterLast('/'))
                URL(url).openStream().use { input ->
                    tempFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                val uri = FileProvider.getUriForFile(this@MainActivity, "${applicationContext.packageName}.provider", tempFile)

                withContext(Dispatchers.Main) {
                    val dragData = ClipData(
                        ClipDescription("Image from YandeReViewer", arrayOf("image/jpeg")),
                        ClipData.Item(uri)
                    )
                    val myShadow = ImageDragShadowBuilder(this@MainActivity, tempFile)

                    window.decorView.rootView.startDragAndDrop(dragData, myShadow, null, View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ)
                }
            } catch (e: Exception) {
                // Handle exception
            }
        }
    }
}