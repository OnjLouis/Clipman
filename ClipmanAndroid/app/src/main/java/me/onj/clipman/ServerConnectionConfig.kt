package me.onj.clipman

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI

data class ServerConnectionDetails(val address: String, val token: String)

object ServerConnectionConfig {
    private val prettyJson = Json { prettyPrint = true }

    fun create(addressValue: String, tokenValue: String): String {
        var address = addressValue.trim().trimEnd('/')
        if (address.startsWith("http://", ignoreCase = true)) {
            address = "clipman://" + address.substring("http://".length)
        } else if (!address.contains("://") && address.isNotEmpty()) {
            address = "clipman://$address"
        }
        val uri = runCatching { URI(address) }.getOrNull()
        val host = uri?.host.orEmpty()
        val port = uri?.port?.takeIf { it > 0 }
            ?: if (uri?.scheme.equals("https", ignoreCase = true)) 443 else 80
        val token = tokenValue.trim().trim('"', '\'', ',', ';')
        require(host.isNotEmpty() && port in 1..65535 && token.isNotEmpty()) {
            "Enter a valid server address, port, and token before exporting."
        }
        val value = buildJsonObject {
            put("clipman", JsonPrimitive("server-connection"))
            put("version", JsonPrimitive(1))
            put("address", JsonPrimitive(address))
            put("host", JsonPrimitive(host))
            put("port", JsonPrimitive(port))
            put("token", JsonPrimitive(token))
        }
        return prettyJson.encodeToString(JsonObject.serializer(), value)
    }

    fun parse(text: String): ServerConnectionDetails {
        val objectValue = Json.parseToJsonElement(text).jsonObject
        require(objectValue["clipman"]?.jsonPrimitive?.content == "server-connection") {
            "This is not a Clipman Server connection file."
        }
        require(objectValue["version"]?.jsonPrimitive?.intOrNull == 1) {
            "This Clipman Server connection-file version is not supported."
        }

        var address = objectValue["address"]?.jsonPrimitive?.content?.trim().orEmpty()
        if (address.isEmpty()) {
            val host = objectValue["host"]?.jsonPrimitive?.content?.trim().orEmpty()
            val port = objectValue["port"]?.jsonPrimitive?.intOrNull ?: -1
            if (host.isNotEmpty() && port in 1..65535) address = "$host:$port"
        }
        if (address.startsWith("http://", ignoreCase = true)) {
            address = "clipman://" + address.substring("http://".length)
        } else if (!address.contains("://") && address.isNotEmpty()) {
            address = "clipman://$address"
        }
        address = address.trimEnd('/')
        val token = objectValue["token"]?.jsonPrimitive?.content?.trim().orEmpty().trim('"', '\'', ',', ';')
        require(address.isNotEmpty() && token.isNotEmpty()) {
            "The connection file does not contain both a server address and token."
        }
        return ServerConnectionDetails(address, token)
    }
}
