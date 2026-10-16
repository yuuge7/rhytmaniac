package com.rhytmaniac.rhytmaniac

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
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
 */
class MainActivity : FlutterActivity() {
    private val channelName = "rhytmaniac/native"
    private val executor = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var channel: MethodChannel

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSaveSource: String? = null

    companion object {
        private const val REQ_PICK_FILE = 4101
        private const val REQ_PICK_FOLDER = 4102
        private const val REQ_CREATE_DOC = 4103
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel.setMethodCallHandler { call, result -> handle(call, result) }
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
            "saveToDownloads" -> background(result) {
                saveToDownloads(
                    call.argument<String>("source")!!,
                    call.argument<String>("name")!!,
                    call.argument<String>("mime") ?: "application/octet-stream",
                )
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("needs_saf")
        }
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
