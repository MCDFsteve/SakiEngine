package dev.aimesoft.erika_flutter

import androidx.lifecycle.Lifecycle

internal fun androidActivityIsActive(state: Lifecycle.State): Boolean =
    state.isAtLeast(Lifecycle.State.STARTED)

internal fun androidActivityActiveForEvent(event: Lifecycle.Event): Boolean? = when (event) {
    Lifecycle.Event.ON_START -> true
    Lifecycle.Event.ON_STOP,
    Lifecycle.Event.ON_DESTROY -> false
    else -> null
}
