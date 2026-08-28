package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPresenterCreateRegistryTest {
    @Test
    fun `detach retires unclaimed handles and rejects late registration`() {
        val registry = AndroidPresenterCreateRegistry<Any>()
        val owner = Any()
        val generation = registry.attach(owner)

        assertTrue(registry.registerIfCurrent(11L, owner, generation))
        assertEquals(listOf(11L), registry.detach(owner).map { it.handle })
        assertFalse(registry.claimIfCurrent(11L, owner, generation))
        assertFalse(registry.registerIfCurrent(12L, owner, generation))
    }

    @Test
    fun `new attachment cannot claim a previous owner handle`() {
        val registry = AndroidPresenterCreateRegistry<Any>()
        val oldOwner = Any()
        val oldGeneration = registry.attach(oldOwner)
        assertTrue(registry.registerIfCurrent(21L, oldOwner, oldGeneration))
        assertEquals(listOf(21L), registry.detach(oldOwner).map { it.handle })

        val newOwner = Any()
        val newGeneration = registry.attach(newOwner)
        assertFalse(registry.claimIfCurrent(21L, newOwner, newGeneration))
        assertTrue(registry.registerIfCurrent(22L, newOwner, newGeneration))
        assertTrue(registry.claimIfCurrent(22L, newOwner, newGeneration))
    }
}
