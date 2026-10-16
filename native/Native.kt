package com.rasam.rasam

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingDns: List<String> = emptyList()
    private var pool: SoundPool? = null
    private val soundIds = HashMap<String, Int>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rasam/sfx").setMethodCallHandler { call, result ->
            if (call.method == "play") {
                try {
                    initSounds()
                    val id = soundIds[call.argument<String>("name") ?: "click"]
                    val v = (call.argument<Double>("volume") ?: 0.7).toFloat()
                    if (id != null) {
                        pool?.play(id, v, v, 1, 0, 1f)
                    }
                } catch (e: Exception) {
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
