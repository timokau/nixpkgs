{ stdenv, buildBazelPackage, lib, fetchFromGitHub, fetchpatch, symlinkJoin
, git
, buildPythonPackage, isPy3k, pythonOlder, pythonAtLeast
, which, binutils, glibcLocales
, python, jemalloc, openmpi
, numpy, tensorflow-tensorboard, backports_weakref, mock, enum34, absl-py
, keras-preprocessing
, keras-applications
, astor
, gast
, termcolor
, cython
, flatbuffers
, giflib
, libjpeg
, grpc
, grpcio
, hwloc
, icu
, jsoncpp
, lmdb
, nasm
, sqlite
, pcre
, libpng
, six
, snappy
, swig
, wrapt
, zlib
, protobuf
, protobuf_cc
, curl
, cudaSupport ? false, nvidia_x11 ? null, cudatoolkit ? null, cudnn ? null
# XLA without CUDA is broken
, xlaSupport ? cudaSupport
# Default from ./configure script
, cudaCapabilities ? [ "3.5" "5.2" ]
, sse42Support ? builtins.elem (stdenv.hostPlatform.platform.gcc.arch or "default") ["westmere" "sandybridge" "ivybridge" "haswell" "broadwell" "skylake" "skylake-avx512"]
, avx2Support  ? builtins.elem (stdenv.hostPlatform.platform.gcc.arch or "default") [                                     "haswell" "broadwell" "skylake" "skylake-avx512"]
, fmaSupport   ? builtins.elem (stdenv.hostPlatform.platform.gcc.arch or "default") [                                     "haswell" "broadwell" "skylake" "skylake-avx512"]
}:

# TODO https://docs.bazel.build/versions/master/skylark/performance.html#profile-and-analyze-profile
# TODO disable sandbox? https://github.com/bazelbuild/bazel/blob/acaca5a9e221088112d4abc6c2b6917e55583e47/src/test/shell/integration/sandboxfs_test.sh#L23

assert cudaSupport -> nvidia_x11 != null
                   && cudatoolkit != null
                   && cudnn != null;

# unsupported combination
assert ! (stdenv.isDarwin && cudaSupport);

let
  withTensorboard = pythonOlder "3.6";

  cudatoolkit_joined = symlinkJoin {
    name = "${cudatoolkit.name}-unsplit";
    paths = [ cudatoolkit.out cudatoolkit.lib ];
  };

  tfFeature = x: if x then "1" else "0";

  version = "1.14";

  pkg = buildBazelPackage rec {
    name = "tensorflow-build-${version}";

    src = fetchFromGitHub {
      owner = "tensorflow";
      repo = "tensorflow";
      rev = "r1.14";
      sha256 = "06jvwlsm14b8rqwd8q8796r0vmn0wk64s4ps2zg0sapkmp9vvcmi";
    };

    patches = [
      # Work around https://github.com/tensorflow/tensorflow/issues/24752
      ./no-saved-proto.patch
    ];

    nativeBuildInputs = [ swig which ];

    buildInputs = [
      python jemalloc openmpi glibcLocales
      git
      # python deps needed during wheel build time
      numpy
      keras-preprocessing
      # libs taken from system through the TF_SYS_LIBS mechanism
      absl-py
      astor
      cython
      flatbuffers
      gast
      giflib
      libjpeg
      grpc
      grpcio
      hwloc
      icu
      jsoncpp
      keras-applications
      lmdb
      nasm
      sqlite
      pcre
      libpng
      six
      snappy
      swig
      termcolor
      wrapt
      zlib
      protobuf
      protobuf_cc
      curl
    ]
      ++ lib.optionals cudaSupport [ cudatoolkit cudnn nvidia_x11 ];

    # Take as many libraries from the system as possible. Keep in sync with
    # list of valid syslibs in
    # https://github.com/perfinion/tensorflow/blob/master/third_party/systemlibs/syslibs_configure.bzl
    SYSLIBS= [
      "absl_py"
      "astor_archive"
      "boringssl"
      "com_github_googleapis_googleapis"
      "com_github_googlecloudplatform_google_cloud_cpp"
      "com_google_protobuf"
      "com_google_protobuf_cc"
      "com_googlesource_code_re2"
      "curl"
      "cython"
      "double_conversion"
      "enum34_archive"
      "flatbuffers"
      "gast_archive"
      "gif_archive"
      "grpc"
      "hwloc"
      "icu"
      "jpeg"
      "jsoncpp_git"
      "keras_applications_archive"
      "lmdb"
      "nasm"
      # "nsync"
      "sqlite"
      # "pasta"
      "pcre"
      "png_archive"
      "protobuf_archive"
      "six_archive"
      "snappy"
      "swig"
      "termcolor_archive"
      "wrapt"
      "zlib_archive"
    ];

    preConfigure = ''
      patchShebangs configure

      # arbitrarily set to the current latest bazel version, overly careful
      export TF_IGNORE_MAX_BAZEL_VERSION=1

      # don't rebuild the world
      export TF_SYSTEM_LIBS=${lib.concatStringsSep " " SYSLIBS}

      export PYTHON_BIN_PATH="${python.interpreter}"
      export PYTHON_LIB_PATH="$NIX_BUILD_TOP/site-packages"
      export TF_NEED_GCP=1
      export TF_NEED_HDFS=1
      export TF_ENABLE_XLA=${tfFeature xlaSupport}
      export CC_OPT_FLAGS=" "
      # https://github.com/tensorflow/tensorflow/issues/14454
      export TF_NEED_MPI=${tfFeature cudaSupport}
      export TF_NEED_CUDA=${tfFeature cudaSupport}
      ${lib.optionalString cudaSupport ''
        export CUDA_TOOLKIT_PATH=${cudatoolkit_joined}
        export TF_CUDA_VERSION=${cudatoolkit.majorVersion}
        export CUDNN_INSTALL_PATH=${cudnn}
        export TF_CUDNN_VERSION=${cudnn.majorVersion}
        export GCC_HOST_COMPILER_PATH=${cudatoolkit.cc}/bin/gcc
        export TF_CUDA_COMPUTE_CAPABILITIES=${lib.concatStringsSep "," cudaCapabilities}
      ''}

      mkdir -p "$PYTHON_LIB_PATH"
    '';

    configurePhase = ''
      runHook preConfigure
      # no flags (options provided by previously set environment variables)
      ./configure

      runHook postConfigure
    '';

    NIX_LDFLAGS = lib.optionals cudaSupport [ "-lcublas" "-lcudnn" "-lcuda" "-lcudart" ];

    hardeningDisable = [ "all" ];

    bazelFlags = [
    ] ++ lib.optional sse42Support "--copt=-msse4.2"
      ++ lib.optional avx2Support "--copt=-mavx2"
      ++ lib.optional fmaSupport "--copt=-mfma"
      ++ lib.optional cudaSupport "--config=cuda";

    bazelTarget = "//tensorflow/tools/pip_package:build_pip_package";

    fetchAttrs = {
      preInstall = ''
        rm -rf $bazelOut/external/{bazel_tools,\@bazel_tools.marker,local_*,\@local_*}
      '';

      sha256 = "1bb09y86ni0rmwg6rrnxwhgdxxj87v83hgs6abaryc31am4n45jh";
    };

    buildAttrs = {
      preBuild = ''
        patchShebangs .
        find -type f -name CROSSTOOL\* -exec sed -i \
          -e 's,/usr/bin/ar,${binutils.bintools}/bin/ar,g' \
          {} \;
      '';

      installPhase = ''
        sed -i 's,.*bdist_wheel.*,cp -rL . "$out"; exit 0,' bazel-bin/tensorflow/tools/pip_package/build_pip_package 
        bazel-bin/tensorflow/tools/pip_package/build_pip_package $PWD/dist
      '';
    };

    dontFixup = true;
  };

in buildPythonPackage rec {
  pname = "tensorflow";
  inherit version;

  src = pkg;

  installFlags = lib.optional (!withTensorboard) "--no-dependencies";

  # Upstream has a pip hack that results in bin/tensorboard being in both tensorflow
  # and the propageted input tensorflow-tensorboard which causes environment collisions.
  # another possibility would be to have tensorboard only in the buildInputs
  # https://github.com/tensorflow/tensorflow/blob/v1.7.1/tensorflow/tools/pip_package/setup.py#L79
  postInstall = ''
    rm $out/bin/tensorboard
  '';

  postPatch = lib.optionalString (pythonAtLeast "3.4") ''
    sed -i '/enum34/d' setup.py
  '';

  propagatedBuildInputs = [
    numpy six protobuf absl-py
    keras-preprocessing
    keras-applications
    astor
    gast
    termcolor
    wrapt
  ] ++ lib.optional (!isPy3k) mock
    ++ lib.optionals (pythonOlder "3.4") [ backports_weakref enum34 ]
    ++ lib.optional withTensorboard tensorflow-tensorboard;

  # Actual tests are slow and impure.
  checkPhase = ''
    ${python.interpreter} -c "import tensorflow"
  '';

  meta = with stdenv.lib; {
    description = "Computation using data flow graphs for scalable machine learning";
    homepage = http://tensorflow.org;
    license = licenses.asl20;
    maintainers = with maintainers; [ jyp abbradar ];
    platforms = platforms.linux;
    broken = !(xlaSupport -> cudaSupport);
  };
}
