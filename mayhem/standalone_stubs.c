/* libFuzzer's mutation entry point, referenced by the pl7m custom mutator but only ever called by libFuzzer itself. */
#include <stddef.h>
#include <stdint.h>

size_t LLVMFuzzerMutate(uint8_t *Data, size_t Size, size_t MaxSize) {
  (void)Data;
  (void)MaxSize;
  return Size;
}
