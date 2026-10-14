package com.rasam.rasam

import android.app.Activity
import android.content.Intent
import android.net.VpnService
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rasam/dns").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val p = call.argument<String>("primary") ?: ""
                    val s = call.argument<String>("secondary") ?: ""
                    pendingDns = listOf(p, s).filter { it.isNotBlank() }
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        launchDns()
                        result.success(true)
                    } else {
                        pending = result
                        startActivityForResult(intent, 77)
                    }
                }
                "stop" -> {
                    startService(Intent(this, DnsVpnService::class.java).setAction("STOP"))
                    result.success(true)
                }
                "isRunning" -> result.success(DnsVpnService.running)
                else -> result.notImplemented()
            }
        }
    }

    private fun launchDns() {
        val i = Intent(this, DnsVpnService::class.java)
        i.putStringArrayListExtra("dns", ArrayList(pendingDns))
        startService(i)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 77) {
            val r = pending
            pending = null
            if (resultCode == Activity.RESULT_OK) {
                launchDns()
                r?.success(true)
            } else {
                r?.success(false)
            }
        } else {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}

class DnsVpnService : VpnService() {
    companion object {
        @Volatile
        var running = false
    }

    private var tun: ParcelFileDescriptor? = null
    private val pool = Executors.newCachedThreadPool()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            stopAll()
            stopSelf()
            return START_NOT_STICKY
        }
        val dns = intent?.getStringArrayListExtra("dns") ?: arrayListOf()
        if (dns.isEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }
        stopAll()
        try {
            val b = Builder().setSession("Rasam DNS").addAddress("10.77.0.2", 32).setBlocking(true)
            for (d in dns) {
                b.addDnsServer(d)
                b.addRoute(d, 32)
            }
            tun = b.establish()
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        val fd = tun
        if (fd == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        Thread { loop(fd) }.start()
        return START_NOT_STICKY
    }

    private fun loop(pfd: ParcelFileDescriptor) {
        val input = FileInputStream(pfd.fileDescriptor)
        val output = FileOutputStream(pfd.fileDescriptor)
        val buf = ByteArray(32767)
        try {
            while (running) {
                val n = input.read(buf)
                if (n < 0) break
                if (n == 0) continue
                val pkt = buf.copyOf(n)
                pool.execute { handle(pkt, output) }
            }
        } catch (e: Exception) {
        }
    }

    private fun handle(p: ByteArray, out: FileOutputStream) {
        try {
            if (p.size < 28) return
            if ((p[0].toInt() shr 4) != 4) return
            val ihl = (p[0].toInt() and 0x0F) * 4
            if (p[9].toInt() != 17) return
            val dport = ((p[ihl + 2].toInt() and 0xFF) shl 8) or (p[ihl + 3].toInt() and 0xFF)
            if (dport != 53) return
            val payload = p.copyOfRange(ihl + 8, p.size)
            val dst = InetAddress.getByAddress(p.copyOfRange(16, 20))
            val sock = DatagramSocket()
            protect(sock)
            sock.soTimeout = 4000
            sock.send(DatagramPacket(payload, payload.size, dst, 53))
            val rbuf = ByteArray(4096)
            val rp = DatagramPacket(rbuf, rbuf.size)
            sock.receive(rp)
            sock.close()
            val rl = rp.length
            val total = 28 + rl
            val r = ByteArray(total)
            r[0] = 0x45
            r[8] = 64
            r[9] = 17
            r[2] = (total shr 8).toByte()
            r[3] = total.toByte()
            System.arraycopy(p, 16, r, 12, 4)
            System.arraycopy(p, 12, r, 16, 4)
            var sum = 0
            for (i in 0 until 20 step 2) {
                sum += ((r[i].toInt() and 0xFF) shl 8) or (r[i + 1].toInt() and 0xFF)
            }
            while ((sum shr 16) != 0) {
                sum = (sum and 0xFFFF) + (sum shr 16)
            }
            val cs = sum.inv() and 0xFFFF
            r[10] = (cs shr 8).toByte()
            r[11] = cs.toByte()
            System.arraycopy(p, ihl + 2, r, 20, 2)
            System.arraycopy(p, ihl, r, 22, 2)
            val ul = 8 + rl
            r[24] = (ul shr 8).toByte()
            r[25] = ul.toByte()
            System.arraycopy(rbuf, 0, r, 28, rl)
            synchronized(out) { out.write(r) }
        } catch (e: Exception) {
        }
    }

    private fun stopAll() {
        running = false
        try {
            tun?.close()
        } catch (e: Exception) {
        }
        tun = null
    }

    override fun onRevoke() {
        stopAll()
        stopSelf()
    }

    override fun onDestroy() {
        stopAll()
        pool.shutdownNow()
        super.onDestroy()
    }
}
