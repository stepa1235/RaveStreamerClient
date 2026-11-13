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
    private var inviteChannel: MethodChannel? = null
    private var pendingInvite: String? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingInvite = inviteFrom(intent)
        if (pendingInvite != null) inviteChannel?.invokeMethod("inviteAvailable", null)
    }

    private fun inviteFrom(intent: Intent?): String? =
        intent?.data?.takeIf { it.scheme == "luna" && it.host == "invite" }?.toString()

    override fun onResume() {
        super.onResume()
        val path = pendingApkPath ?: return
        pendingApkPath = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
            try {
                openInstaller(File(path))
            } catch (error: Exception) {
                android.widget.Toast.makeText(this, "Luna: installer could not open", android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun openInstaller(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.install_apk.fileprovider", file)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            setDataAndType(uri, "application/vnd.android.package-archive")
        })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingInvite = pendingInvite ?: inviteFrom(intent)
        inviteChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "luna/invites").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeInvite") {
                    val value = pendingInvite
                    pendingInvite = null
                    result.success(value)
                } else {
                    result.notImplemented()
                }
            }
        }
        volumeControlStream = android.media.AudioManager.STREAM_MUSIC
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    try {
                        val file = File(requireNotNull(call.argument<String>("filePath"))).canonicalFile
                        require(file.isFile && file.name == "Luna.apk" &&
                            file.parentFile?.name?.startsWith("luna-update-") == true &&
                            file.parentFile?.parentFile == cacheDir.canonicalFile)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            pendingApkPath = file.path
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        } else {
                            openInstaller(file)
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        pendingApkPath = null
                        result.error("INSTALL_ERROR", "Could not open Luna installer", null)
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        inviteChannel?.setMethodCallHandler(null)
        inviteChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
