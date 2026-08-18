export const COARSE_POINTER_QUERY = "(pointer: coarse)"

/**
 * The Ghostty textarea should own terminal focus without implicitly owning the
 * OS keyboard. Coarse-pointer clients opt into text input only through the
 * explicit keyboard control; fine-pointer clients keep normal text input for
 * physical keyboards.
 */
export function terminalInputMode({coarsePointer = false, keyboardRequested = false} = {}) {
  return coarsePointer && !keyboardRequested ? "none" : "text"
}
