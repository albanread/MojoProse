//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#include "Support/Random.h"
#include "Support/ErrorOr.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/Twine.h"

#ifdef __linux__
#include <sys/random.h>
#endif // __linux__

#ifdef __HAIKU__
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <unistd.h>
#endif // __HAIKU__

#ifdef _WIN32
#include <windows.h>

#include <wincrypt.h>
#endif // _WIN32

using namespace M;

SecureRandomBytesGenerator::SecureRandomBytesGenerator() {
#ifdef _WIN32
  if (!CryptAcquireContext(
          (HCRYPTPROV *)&ctx, NULL,
          (LPCWSTR)L"Microsoft Base Cryptographic Provider v1.0", PROV_RSA_FULL,
          CRYPT_VERIFYCONTEXT))
    llvm::report_fatal_error("could not acquire the context for the csprng");
#endif // _WIN32
}

SecureRandomBytesGenerator::~SecureRandomBytesGenerator() {
#ifdef _WIN32
  CryptReleaseContext((HCRYPTPROV)ctx, 0);
#endif // _WIN32
}

ErrorOrSuccess
SecureRandomBytesGenerator::getRandomBytes(MutableArrayRef<uint8_t> buf) {
#if defined(__APPLE__)
  arc4random_buf(buf.data(), buf.size());
  return success();
#elif defined(__linux__)
  ssize_t rc = 0;
  size_t bytesNeeded = buf.size();
  uint8_t *bufPtr = buf.data();
  do {
    rc = getrandom(bufPtr, bytesNeeded, 0);
    if (rc < 0)
      return Error("random read failed with " + Twine((int)rc));
    bufPtr += rc;
    bytesNeeded -= rc;
  } while (bytesNeeded > 0);
  return success();
#elif defined(_WIN32)
  if (CryptGenRandom((HCRYPTPROV)ctx, buf.size(), buf.data()))
    return Error("random read failed");
  return success();
#elif defined(__HAIKU__)
  // getentropy() fills at most 256 bytes a call.
  for (size_t offset = 0; offset < buf.size(); offset += 256) {
    size_t length = std::min<size_t>(256, buf.size() - offset);
    if (getentropy(buf.data() + offset, length) != 0)
      return Error("getentropy failed: " + Twine(strerror(errno)));
  }
  return success();
#endif // __APPLE__ | __linux__ | _WIN32 | __HAIKU__
  return Error("unsupported platform - could not generate random data");
}
