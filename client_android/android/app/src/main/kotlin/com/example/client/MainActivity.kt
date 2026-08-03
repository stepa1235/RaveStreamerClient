package com.example.client

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.client/permissions"
    private var pendingApkPath: String? = null

    override fun onResume() {
        super.onResume()
        pendingApkPath?.let { path ->
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
                val fileToInstall = pendingApkPath
                pendingApkPath = null
                try {
                    val file = File(fileToInstall!!)
                    if (file.exists()) {
                        val authority = "${context.packageName}.install_apk.fileprovider"
                        val apkUri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            FileProvider.getUriForFile(context, authority, file)
                        } else {
                            Uri.fromFile(file)
                        }
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                            setDataAndType(apkUri, "application/vnd.android.package-archive")
                        }
                        startActivity(intent)
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeControlStream = android.media.AudioManager.STREAM_MUSIC
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestInstallPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        if (!packageManager.canRequestPackageInstalls()) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                                startActivity(intent)
                                result.success(false)
                                return@setMethodCallHandler
                            } catch (e: Exception) {
                                result.error("ERROR", e.message, null)
                                return@setMethodCallHandler
                            }
                        }
                    }
                    result.success(true)
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("INVALID_PATH", "File path is null", null)
                        return@setMethodCallHandler
                    }
                    pendingApkPath = filePath
                    try {
                        val file = File(filePath)
                        if (!file.exists()) {
                            result.error("FILE_NOT_FOUND", "APK file does not exist", null)
                            return@setMethodCallHandler
                        }
                        
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                        }
                        
                        val authority = "${context.packageName}.install_apk.fileprovider"
                        val apkUri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            try {
                                FileProvider.getUriForFile(context, authority, file)
                            } catch (e: Exception) {
                                Uri.fromFile(file)
                            }
                        } else {
                            Uri.fromFile(file)
                        }
                        
                        intent.setDataAndType(apkUri, "application/vnd.android.package-archive")
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                "setMediaAudioMode" -> {
                    try {
                        volumeControlStream = android.media.AudioManager.STREAM_MUSIC
                        val audioManager = getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
                        audioManager.mode = android.media.AudioManager.MODE_NORMAL
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                            audioManager.clearCommunicationDevice()
                        }
                        @Suppress("DEPRECATION")
                        audioManager.isSpeakerphoneOn = true
                        
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                            val focusRequest = android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN)
                                .setAudioAttributes(
                                    android.media.AudioAttributes.Builder()
                                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                                        .build()
                                )
                                .build()
                            audioManager.requestAudioFocus(focusRequest)
                        } else {
                            @Suppress("DEPRECATION")
                            audioManager.requestAudioFocus(null, android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.AUDIOFOCUS_GAIN)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
