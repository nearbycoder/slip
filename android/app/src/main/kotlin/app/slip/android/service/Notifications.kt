package app.slip.android.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import app.slip.android.R
import app.slip.android.ui.MainActivity
import app.slip.android.ui.formatSize
import app.slip.core.server.IncomingRequest
import app.slip.core.server.TextMessage

object Notifications {
    const val CHANNEL_SERVICE = "service"
    const val CHANNEL_REQUESTS = "requests"
    const val ID_SERVICE = 1
    const val ID_REQUEST = 2
    const val ID_MESSAGE = 3
    const val ID_DONE = 4

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_SERVICE, context.getString(R.string.channel_service), NotificationManager.IMPORTANCE_LOW)
                .apply { description = context.getString(R.string.channel_service_desc); setShowBadge(false) },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_REQUESTS, context.getString(R.string.channel_requests), NotificationManager.IMPORTANCE_HIGH)
                .apply { description = context.getString(R.string.channel_requests_desc) },
        )
    }

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun serviceAction(context: Context, action: String, code: Int): PendingIntent = PendingIntent.getService(
        context, code, Intent(context, SlipService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun service(context: Context, title: String, text: String, progress: Int? = null) =
        NotificationCompat.Builder(context, CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(context, R.color.slip_green))
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(openApp(context))
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply { if (progress != null) setProgress(100, progress, progress < 0) }
            .addAction(0, "Stop", serviceAction(context, SlipService.ACTION_STOP, 3))
            .build()

    fun request(context: Context, req: IncomingRequest) = NotificationCompat.Builder(context, CHANNEL_REQUESTS)
        .setSmallIcon(R.drawable.ic_notification)
        .setColor(ContextCompat.getColor(context, R.color.slip_green))
        .setContentTitle("${req.sender.alias} wants to send ${req.files.size} file${if (req.files.size == 1) "" else "s"}")
        .setContentText("${formatSize(req.totalSize)} · ${req.files.take(3).joinToString { it.fileName }}${if (req.files.size > 3) "…" else ""}")
        .setStyle(NotificationCompat.BigTextStyle().bigText(req.files.take(10).joinToString("\n") { "${it.fileName} (${formatSize(it.size)})" }))
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        .setCategory(NotificationCompat.CATEGORY_CALL)
        .setContentIntent(openApp(context))
        .setAutoCancel(true)
        .setTimeoutAfter(60_000)
        .addAction(0, "Accept", serviceAction(context, SlipService.ACTION_ACCEPT, 1))
        .addAction(0, "Decline", serviceAction(context, SlipService.ACTION_DECLINE, 2))
        .build()

    fun message(context: Context, msg: TextMessage) = NotificationCompat.Builder(context, CHANNEL_REQUESTS)
        .setSmallIcon(R.drawable.ic_notification)
        .setColor(ContextCompat.getColor(context, R.color.slip_green))
        .setContentTitle("Message from ${msg.sender.alias}")
        .setContentText(msg.text)
        .setStyle(NotificationCompat.BigTextStyle().bigText(msg.text))
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        .setContentIntent(openApp(context))
        .setAutoCancel(true)
        .build()

    fun done(context: Context, title: String, text: String) = NotificationCompat.Builder(context, CHANNEL_REQUESTS)
        .setSmallIcon(R.drawable.ic_notification)
        .setColor(ContextCompat.getColor(context, R.color.slip_green))
        .setContentTitle(title)
        .setContentText(text)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .setContentIntent(openApp(context))
        .setAutoCancel(true)
        .build()
}
