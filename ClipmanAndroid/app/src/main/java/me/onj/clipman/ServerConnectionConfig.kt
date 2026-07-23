package me.onj.clipman

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class ServerConnectionDetails(val address: String, val token: String)

object ServerConnectionConfig {
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
