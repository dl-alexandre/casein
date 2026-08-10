defmodule CaseinMob.AndroidCmakeZigFallbackTest do
  use ExUnit.Case, async: true

  # Issue #408 — standalone Gradle/CMake must consume Zig-native artifacts (or
  # fail closed with Mix/Zig instructions). It must not compile removed Mob
  # 0.7.5 C sources. These tests exercise the CMake fallback branches directly
  # via `cmake` configure; they do not run `./gradlew assembleDebug` or the
  # Mix happy path.

  @cmake_lists Path.expand("../../android/app/src/main/jni/CMakeLists.txt", __DIR__)
  @abi "arm64-v8a"

  test "CMakeLists retires the Mob 0.7.5 C source fallback and names Zig artifacts" do
    source = File.read!(@cmake_lists)

    # Compile inputs for casein_mob may only be Zig .o / IMPORTED .so — never
    # the removed Mob 0.7.5 C files. Strip comments so prose may still name them.
    code_only =
      source
      |> String.split("\n")
      |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
      |> Enum.join("\n")

    refute code_only =~ "${MOB_DIR}/android/jni/mob_nif.c"
    refute code_only =~ "${MOB_DIR}/android/jni/mob_beam.c"
    refute code_only =~ "PROJECT_NIF_C_SRCS"
    refute code_only =~ "file(GLOB PROJECT_NIF"
    refute code_only =~ "${DRIVER_TAB_ANDROID}"
    refute code_only =~ "driver_tab_android.c"
    # beam_jni.c remains in-tree for Zig; CMake must not list it as a C source.
    refute code_only =~ ~r|add_library\s*\(\s*casein_mob\s+SHARED\s*\n\s*beam_jni\.c|

    assert source =~ "libcasein_mob.so"
    assert source =~ "driver_tab_android.o"
    assert source =~ "mob_nif.o"
    assert source =~ "mob_beam.o"
    assert source =~ "beam_jni.o"
    assert source =~ "mix mob.deploy --native --android"
    assert source =~ "FATAL_ERROR"
  end

  test "cmake configure consumes prebuilt jniLibs Zig .so artifacts (fallback path 1)" do
    cmake = find_cmake!()

    with_cmake_project_tree(fn root ->
      jni_libs = Path.join(root, "android/app/src/main/jniLibs/#{@abi}")
      File.mkdir_p!(jni_libs)
      File.write!(Path.join(jni_libs, "libcasein_mob.so"), "fake-zig-so")
      File.write!(Path.join(jni_libs, "libsqlite3_nif.so"), "fake-zig-sqlite")

      {output, status} = configure_cmake(cmake, root)
      assert status == 0, output
      assert File.exists?(Path.join(root, "build/CMakeCache.txt"))
      assert output =~ "Configuring done" or status == 0
    end)
  end

  test "cmake configure consumes zig-out object files (fallback path 2)" do
    cmake = find_cmake!()

    with_cmake_project_tree(fn root ->
      zig_out = Path.join(root, "android/app/build/zig-out/#{@abi}")
      File.mkdir_p!(zig_out)

      for name <- ~w(driver_tab_android.o beam_jni.o mob_nif.o mob_beam.o) do
        File.write!(Path.join(zig_out, name), <<0>>)
      end

      # Object-link path still needs either jniLibs sqlite .so or deps/exqlite sources.
      jni_libs = Path.join(root, "android/app/src/main/jniLibs/#{@abi}")
      File.mkdir_p!(jni_libs)
      File.write!(Path.join(jni_libs, "libsqlite3_nif.so"), "fake-zig-sqlite")

      {output, status} = configure_cmake(cmake, root)
      assert status == 0, output
      assert File.exists?(Path.join(root, "build/CMakeCache.txt"))
    end)
  end

  test "cmake configure fails closed with Mix/Zig instructions when no Zig artifacts exist" do
    cmake = find_cmake!()

    with_cmake_project_tree(fn root ->
      {output, status} = configure_cmake(cmake, root)
      assert status != 0, "expected configure failure without Zig artifacts, got:\n#{output}"
      assert output =~ "mix mob.deploy --native --android"
      assert output =~ "no Zig-native artifacts" or output =~ "Standalone Gradle/CMake"
      assert output =~ "retired" or output =~ "no longer ship"
      # Fail-closed: must not attempt to compile removed C sources.
      refute output =~ "Building C object"
      refute output =~ "Cannot find source file"
    end)
  end

  test "cmake configure rejects jniLibs main .so without matching sqlite .so" do
    cmake = find_cmake!()

    with_cmake_project_tree(fn root ->
      jni_libs = Path.join(root, "android/app/src/main/jniLibs/#{@abi}")
      File.mkdir_p!(jni_libs)
      File.write!(Path.join(jni_libs, "libcasein_mob.so"), "fake-zig-so")

      {output, status} = configure_cmake(cmake, root)
      assert status != 0, output
      assert output =~ "libsqlite3_nif.so"
      assert output =~ "mix mob.deploy --native --android"
    end)
  end

  defp find_cmake! do
    candidates =
      [
        System.find_executable("cmake"),
        System.get_env("CMAKE"),
        "/tmp/opencode/cmake-install/bin/cmake"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&File.regular?/1)

    case candidates do
      [cmake | _] ->
        cmake

      [] ->
        flunk("""
        cmake is required to exercise the standalone Android CMake fallback (#408).
        Install CMake ≥ 3.22 or set CMAKE=/path/to/cmake.
        """)
    end
  end

  defp with_cmake_project_tree(fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "casein-cmake-zig-fallback-#{System.unique_integer([:positive])}"
      )

    jni_dir = Path.join(root, "android/app/src/main/jni")
    File.mkdir_p!(jni_dir)
    File.cp!(@cmake_lists, Path.join(jni_dir, "CMakeLists.txt"))
    File.mkdir_p!(Path.join(root, "build"))

    try do
      fun.(root)
    after
      File.rm_rf(root)
    end
  end

  defp configure_cmake(cmake, root) do
    build = Path.join(root, "build")
    jni = Path.join(root, "android/app/src/main/jni")

    args = [
      "-S",
      jni,
      "-B",
      build,
      "-DANDROID_ABI=#{@abi}",
      "-DOTP_RELEASE=/nonexistent-otp",
      "-DOTP_RELEASE_ARM32=/nonexistent-otp",
      "-DOTP_RELEASE_X86_64=/nonexistent-otp",
      "-DERTS_VSN=erts-17.0",
      "-DMOB_DIR=/nonexistent-mob"
    ]

    System.cmd(cmake, args, stderr_to_stdout: true)
  end
end
