package com.example.iset_community

import android.bluetooth.BluetoothManager
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.iset.community/files"
        private const val DEVICE_CHANNEL = "com.iset.community/device"
        private const val FOLDER = "ISET Community Hub files"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveReceivedFile" -> {
                    val source = call.argument<String>("source")
                    val name = call.argument<String>("name")
                    if (source == null || name == null) {
                        result.error("INVALID_ARGUMENTS", "source and name are required", null)
                    } else {
                        try {
                            val safeName = File(name).name.ifEmpty { "received_file" }
                            if (saveReceivedFile(source, safeName)) {
                                result.success(true)
                            } else {
                                result.error("SAVE_FAILED", "Could not save $safeName", null)
                            }
                        } catch (e: Exception) {
                            result.error(
                                "SAVE_FAILED",
                                e.message ?: "Could not save the received file",
                                null,
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "bluetoothEnabled" -> result.success(isBluetoothEnabled())
                    else -> result.notImplemented()
                }
            }
    }

    private fun isBluetoothEnabled(): Boolean = try {
        getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
    } catch (_: SecurityException) {
        false
    } catch (_: Exception) {
        false
    }

    private fun saveReceivedFile(source: String, name: String): Boolean {
        return try {
            val sourceUri = Uri.parse(source)
            val input = contentResolver.openInputStream(sourceUri) ?: return false

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER",
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: return false
                val output = contentResolver.openOutputStream(uri) ?: return false
                input.use { it.copyTo(output) }
                output.close()

                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } else {
                @Suppress("DEPRECATION")
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    FOLDER,
                )
                dir.mkdirs()
                val output = FileOutputStream(File(dir, name))
                input.use { it.copyTo(output) }
                output.close()
            }

            contentResolver.delete(sourceUri, null, null)
            true
        } catch (e: Exception) {
            false
        }
    }
}
