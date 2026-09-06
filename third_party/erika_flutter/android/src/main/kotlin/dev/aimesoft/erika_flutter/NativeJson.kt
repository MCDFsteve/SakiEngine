package dev.aimesoft.erika_flutter

import org.json.JSONArray
import org.json.JSONObject

internal data class NativeResponse(
    val ok: Boolean,
    val status: Int,
    val error: String?,
    val value: Any?,
) {
    companion object {
        fun success(value: Any? = null) = NativeResponse(true, 0, null, value)
    }
}

internal fun normalizedOptionalEventResponse(response: NativeResponse?): NativeResponse? =
    response?.takeUnless { it.ok && it.value == null }

internal object NativeJson {
    fun encodeArguments(arguments: Map<String, Any?>): String {
        val json = JSONObject()
        arguments.forEach { (key, value) -> json.put(key, toJsonValue(value)) }
        return json.toString()
    }

    fun decodeResponse(raw: String): NativeResponse {
        val json = JSONObject(raw)
        val ok = json.optBoolean("ok", false)
        val status = when (val value = json.opt("status")) {
            is Number -> value.toInt()
            is String -> value.toIntOrNull() ?: if (ok) 0 else -1
            else -> if (ok) 0 else -1
        }
        val error = if (json.has("error") && !json.isNull("error")) {
            json.optString("error").takeIf { it.isNotBlank() }
        } else {
            null
        }
        val value = if (json.has("value")) fromJsonValue(json.opt("value")) else null
        return NativeResponse(ok, status, error, value)
    }

    /**
     * Event polling uses a successful null payload to represent an empty native queue.
     * Normalize both that representation and an actual JNI null to Kotlin null so callers
     * do not spin while treating empty responses as real events.
     */
    fun decodeOptionalEventResponse(raw: String?): NativeResponse? {
        if (raw == null) {
            return null
        }
        return normalizedOptionalEventResponse(decodeResponse(raw))
    }

    private fun toJsonValue(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Boolean, is Number, is String -> value
        is Map<*, *> -> JSONObject().also { objectValue ->
            value.forEach { (key, child) ->
                if (key != null) {
                    objectValue.put(key.toString(), toJsonValue(child))
                }
            }
        }
        is Iterable<*> -> JSONArray().also { array ->
            value.forEach { child -> array.put(toJsonValue(child)) }
        }
        is Array<*> -> JSONArray().also { array ->
            value.forEach { child -> array.put(toJsonValue(child)) }
        }
        else -> value.toString()
    }

    private fun fromJsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> linkedMapOf<String, Any?>().also { result ->
            val keys = value.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                result[key] = fromJsonValue(value.opt(key))
            }
        }
        is JSONArray -> List(value.length()) { index ->
            fromJsonValue(value.opt(index))
        }
        else -> value
    }
}
