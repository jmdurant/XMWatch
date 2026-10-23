package xmwatch.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream

/** Bounded metadata artwork keeps media-session Binder updates small. */
object MediaArtwork {
    fun thumbnail(bytes: ByteArray): ByteArray? {
        if (bytes.size>8*1024*1024) return null
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
        if (bounds.outWidth !in 1..100000 || bounds.outHeight !in 1..100000) return null
        var sample=1
        while (maxOf(bounds.outWidth,bounds.outHeight)/sample>512) sample*=2
        val options=BitmapFactory.Options().apply { inSampleSize=sample }
        val bitmap=BitmapFactory.decodeByteArray(bytes,0,bytes.size,options) ?: return null
        return try {
            val output=ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG,80,output)
            output.toByteArray().takeIf { it.size<=256*1024 }
        } finally { bitmap.recycle() }
    }
}
