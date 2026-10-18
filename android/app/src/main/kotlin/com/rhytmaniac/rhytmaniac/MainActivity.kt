package com.rhytmaniac.rhytmaniac

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.view.WindowManager
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors

/**
 * Native bridge for things Flutter plugins don't cover well:
 * - Storage Access Framework picking (files, folders) and saving.
 * - Saving exports into the public Downloads folder via MediaStore.
 * - Audio decoding (MediaExtractor + MediaCodec) to mono 16-bit PCM.
 * - Tag / cover extraction (MediaMetadataRetriever).
 * Music and hit sounds live in [GameAudio] on the `rhytmaniac/audio` channel.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "rhytmaniac/native"
    private val executor = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var channel: MethodChannel
    private var audio: GameAudio? = null

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSaveSource: String? = null

    /** A Downloads save waiting for the storage permission (Android 9 and older). */
    private var pendingDownload: Triple<String, String, MethodChannel.Result>? = null

    /** A file another app opened or shared with us, until Dart takes it. */
    private var openedFile: Map<String, Any?>? = null

    companion object {
        private const val REQ_PICK_FILE = 4101
        private const val REQ_PICK_FOLDER = 4102
        private const val REQ_CREATE_DOC = 4103
        private const val REQ_WRITE_STORAGE = 4104
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        val audioChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rhytmaniac/audio")
        val engine = GameAudio(applicationContext, audioChannel)
        audioChannel.setMethodCallHandler { call, result -> engine.handle(call, result) }
        audio = engine
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Re-created after the process was killed: the intent was handled.
        if (savedInstanceState == null) captureOpenedFile(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (captureOpenedFile(intent)) channel.invokeMethod("fileOpened", null)
    }

    /** "Open with" (VIEW) or "Share" (SEND) from another app. */
    private fun captureOpenedFile(intent: Intent?): Boolean {
        val uri: Uri? = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            else -> null
        }
        if (uri == null) return false
        openedFile = try {
            describe(uri)
        } catch (_: Exception) {
            mapOf("uri" to uri.toString(), "name" to (uri.lastPathSegment ?: "file"), "size" to null, "mime" to intent?.type)
        }
        return true
    }

    /** Fastest mode at the current resolution, or the one nearest 60 Hz. */
    private fun setHighRefreshRate(on: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        @Suppress("DEPRECATION")
        val display = (if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay) ?: return
        val current = display.mode
        val modes = display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight
        }
        val target = (if (on) modes.maxByOrNull { it.refreshRate } else modes.minByOrNull { kotlin.math.abs(it.refreshRate - 60f) })
            ?: return
        val params: WindowManager.LayoutParams = window.attributes
        if (params.preferredDisplayModeId != target.modeId) {
            params.preferredDisplayModeId = target.modeId
            window.attributes = params
        }
    }

    override fun onPause() {
        super.onPause()
        // Music never keeps playing behind another app or the home screen.
        audio?.onHostPause()
    }

    override fun onDestroy() {
        audio?.release()
        audio = null
        super.onDestroy()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFile" -> pickFile(call.argument<List<String>>("mimeTypes") ?: listOf("*/*"), result)
            "pickFolder" -> pickFolder(result)
            "createDocument" -> createDocument(
                call.argument<String>("source")!!,
                call.argument<String>("name")!!,
                call.argument<String>("mime") ?: "application/octet-stream",
                result,
            )
            "copyUri" -> background(result) {
                copyUri(Uri.parse(call.argument<String>("uri")!!), File(call.argument<String>("dest")!!))
            }
            "readMetadata" -> background(result) {
                MediaTools.readMetadata(call.argument<String>("path")!!, call.argument<String>("coverPath")!!)
            }
            "decodeAudio" -> {
                val id = call.argument<String>("id") ?: ""
                background(result) {
                    MediaTools.decodeToMonoPcm16(
                        call.argument<String>("path")!!,
                        call.argument<String>("dest")!!,
                        call.argument<Int>("sampleRate") ?: 22050,
                    ) { p -> main.post { channel.invokeMethod("decodeProgress", mapOf("id" to id, "progress" to p)) } }
                }
            }
            "saveToDownloads" -> {
                val source = call.argument<String>("source")!!
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                    checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                ) {
                    // Ask once; the answer arrives in onRequestPermissionsResult.
                    if (pendingDownload != null) {
                        result.error("busy", "Already asking for storage access", null)
                    } else {
                        pendingDownload = Triple(source, name, result)
                        requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQ_WRITE_STORAGE)
                    }
                } else {
                    background(result) { saveToDownloads(source, name, mime) }
                }
            }
            "saveToFolder" -> background(result) {
                saveToFolder(
                    Uri.parse(call.argument<String>("treeUri")!!),
                    call.argument<String>("source")!!,
                    call.argument<String>("name")!!,
                    call.argument<String>("mime") ?: "application/octet-stream",
                )
            }
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "takeOpenedFile" -> {
                result.success(openedFile)
                openedFile = null
            }
            "setHighRefreshRate" -> {
                setHighRefreshRate(call.argument<Boolean>("on") ?: true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun <T> background(result: MethodChannel.Result, work: () -> T) {
        executor.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error(e.javaClass.simpleName, e.message ?: e.toString(), null) }
            }
        }
    }

    // --- Storage Access Framework -------------------------------------------------

    private fun takePending(result: MethodChannel.Result): Boolean {
        if (pendingResult != null) {
            result.error("busy", "Another picker is already open", null)
            return false
        }
        pendingResult = result
        return true
    }

    private fun pickFile(mimeTypes: List<String>, result: MethodChannel.Result) {
        if (!takePending(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mimeTypes.size == 1) mimeTypes[0] else "*/*"
            if (mimeTypes.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
        }
        startActivityForResult(intent, REQ_PICK_FILE)
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (!takePending(result)) return
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_PICK_FOLDER)
    }

    private fun createDocument(source: String, name: String, mime: String, result: MethodChannel.Result) {
        if (!takePending(result)) return
        pendingSaveSource = source
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        startActivityForResult(intent, REQ_CREATE_DOC)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_WRITE_STORAGE) return
        val (source, name, result) = pendingDownload ?: return
        pendingDownload = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            background(result) { saveToDownloads(source, name, "application/octet-stream") }
        } else {
            // Without the permission, Dart falls back to the system save dialog.
            result.error("UnsupportedOperationException", "needs_saf", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val result = pendingResult ?: return
        if (requestCode !in listOf(REQ_PICK_FILE, REQ_PICK_FOLDER, REQ_CREATE_DOC)) return
        pendingResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        when (requestCode) {
            REQ_PICK_FILE -> result.success(describe(uri))
            REQ_PICK_FOLDER -> {
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                }
                result.success(mapOf("uri" to uri.toString(), "name" to treeName(uri)))
            }
            REQ_CREATE_DOC -> {
                val source = pendingSaveSource
                pendingSaveSource = null
                if (source == null) {
                    result.success(null)
                    return
                }
                background(result) {
                    contentResolver.openOutputStream(uri, "w")!!.use { out ->
                        FileInputStream(source).use { it.copyTo(out, 1 shl 16) }
                    }
                    (describe(uri)["name"] as? String) ?: uri.toString()
                }
            }
        }
    }

    private fun describe(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long? = null
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0) name = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: uri.lastPathSegment ?: "file"),
            "size" to size,
            "mime" to contentResolver.getType(uri),
        )
    }

    private fun treeName(tree: Uri): String {
        return try {
            val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null } ?: "Folder"
        } catch (_: Exception) {
            "Folder"
        }
    }

    private fun copyUri(uri: Uri, dest: File): Long {
        dest.parentFile?.mkdirs()
        contentResolver.openInputStream(uri)!!.use { input ->
            dest.outputStream().use { output -> return input.copyTo(output, 1 shl 16) }
        }
    }

    // --- Saving exports -------------------------------------------------------------

    private fun saveToDownloads(source: String, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return saveToDownloadsLegacy(source, name)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Rhytmaniac")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Could not create the file in Downloads")
        resolver.openOutputStream(uri, "w")!!.use { out ->
            FileInputStream(source).use { it.copyTo(out, 1 shl 16) }
        }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return "Download/Rhytmaniac/$name"
    }

    /** Android 9 and older: write the file straight into Download/Rhytmaniac. */
    @Suppress("DEPRECATION")
    private fun saveToDownloadsLegacy(source: String, name: String): String {
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Rhytmaniac")
        if (!dir.exists() && !dir.mkdirs()) throw IllegalStateException("Could not create Download/Rhytmaniac")
        // Never overwrite: "name (2).ext" and so on.
        val dot = name.indexOf('.').let { if (it <= 0) name.length else it }
        var target = File(dir, name)
        var n = 2
        while (target.exists()) {
            target = File(dir, "${name.substring(0, dot)} ($n)${name.substring(dot)}")
            n++
        }
        FileInputStream(source).use { input -> target.outputStream().use { input.copyTo(it, 1 shl 16) } }
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), null, null)
        return "Download/Rhytmaniac/${target.name}"
    }

    private fun saveToFolder(tree: Uri, source: String, name: String, mime: String): String {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val doc = DocumentsContract.createDocument(contentResolver, parent, mime, name)
            ?: throw IllegalStateException("Could not create the file in the chosen folder")
        contentResolver.openOutputStream(doc, "w")!!.use { out ->
            FileInputStream(source).use { it.copyTo(out, 1 shl 16) }
        }
        return "${treeName(tree)}/$name"
    }
}
