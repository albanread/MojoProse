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
//
// MojoProse reports no crashes anywhere. Upstream starts a crashpad handler
// that uploads a dump of a crashed compiler to crash-reporting.modular.com;
// that is for Modular, not for a Haiku development tool, and crashpad does not
// build for Haiku. The functions keep their contracts: there is never a
// handler to find, initializing starts nothing, and no dump is ever taken.
// LLVM's stack trace on a crash is separate and unchanged.
//
//===----------------------------------------------------------------------===//

#include "Support/CrashReporting/CrashReporting.h"

#include "Support/Error.h"
#include "Support/ErrorOr.h"

using namespace M;

std::filesystem::path
M::getCrashDatabasePath(const std::filesystem::path &dataFolder) {
  return dataFolder / "crashdb";
}

ErrorOr<std::filesystem::path> M::getCrashpadHandlerPath(Config *) {
  return Error("crash reporting is not part of this build");
}

void M::initCrashpadForProgram(StringRef, StringRef, StringRef, Config *) {}

void M::generateNonFatalDump() {}
