package com.alicejump.danbooru_viewer

import android.content.ClipData
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Point
import android.graphics.drawable.BitmapDrawable
import android.media.ThumbnailUtils
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.core.graphics.drawable.toBitmap
import androidx.core.view.ViewCompat
import java.io.File
import kotlin.math.roundToInt

object DragHelper {

    fun startImageDrag(view: View, path: String, type: String) {
        val context = view.context
        val imageFile = File(path)

        if (!imageFile.exists()) {
            Toast.makeText(context, "图片文件不存在，无法拖拽", Toast.LENGTH_SHORT).show()
            return
        }

        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.provider",
            imageFile
        )

        val clipData = ClipData.newUri(
            context.contentResolver,
            "Dragged Image",
            uri
        )

        view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)

        val shadowBuilder = createDragShadowBuilder(view, path, type)

        ViewCompat.startDragAndDrop(
            view,
            clipData,
            shadowBuilder,
            null,
            View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ
        )
    }

    private fun createDragShadowBuilder(view: View, path: String, type: String): View.DragShadowBuilder {
        val context = view.context
        val minSize = 200 * context.resources.displayMetrics.density

        try {
            val bitmap: Bitmap? = if (type == "video") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ThumbnailUtils.createVideoThumbnail(File(path), android.util.Size(minSize.roundToInt(), minSize.roundToInt()), null)
                } else {
                    @Suppress("DEPRECATION")
                    ThumbnailUtils.createVideoThumbnail(path, android.provider.MediaStore.Images.Thumbnails.MINI_KIND)
                }
            } else {
                val options = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeFile(path, options)
                val srcWidth = options.outWidth
                val srcHeight = options.outHeight

                val scale = if (srcWidth < srcHeight) minSize / srcWidth else minSize / srcHeight

                val sampleSize = if (scale < 1) 1 else (1 / scale).roundToInt()

                val newOptions = android.graphics.BitmapFactory.Options().apply { inSampleSize = sampleSize }
                android.graphics.BitmapFactory.decodeFile(path, newOptions)
            }

            if (bitmap != null) {
                val width = bitmap.width
                val height = bitmap.height

                val scale = if (width < height) minSize / width else minSize / height
                val scaledWidth = (width * scale).roundToInt()
                val scaledHeight = (height * scale).roundToInt()

                val scaledBitmap = Bitmap.createScaledBitmap(bitmap, scaledWidth, scaledHeight, true)
                val drawable = BitmapDrawable(context.resources, scaledBitmap)

                return object : View.DragShadowBuilder(view) {
                    override fun onProvideShadowMetrics(outShadowSize: Point, outShadowTouchPoint: Point) {
                        outShadowSize.set(scaledWidth, scaledHeight)
                        outShadowTouchPoint.set(scaledWidth / 2, scaledHeight / 2)
                    }

                    override fun onDrawShadow(canvas: Canvas) {
                        drawable.setBounds(0, 0, scaledWidth, scaledHeight)
                        drawable.draw(canvas)
                    }
                }
            }
        } catch (e: Exception) {
            // Fallback to default shadow
        }

        return View.DragShadowBuilder(view)
    }
}
