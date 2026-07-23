package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ServerConnectionConfigTest {
    @Test
    fun parsesPortableConnectionFile() {
        val details = ServerConnectionConfig.parse(
            """{"clipman":"server-connection","version":1,"address":"clipman://server.example:54321","host":"server.example","port":54321,"token":"test-token"}"""
        )
        assertEquals("clipman://server.example:54321", details.address)
        assertEquals("test-token", details.token)
    }

    @Test
    fun rejectsUnrelatedJson() {
        assertThrows(IllegalArgumentException::class.java) {
            ServerConnectionConfig.parse("""{"address":"clipman://server.example:54321","token":"test-token"}""")
        }
    }
}
