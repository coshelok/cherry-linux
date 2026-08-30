# This is a -*-perl-*- script
#
# Set variables that were defined by configure, in case we need them
# during the tests.

%CONFIG_FLAGS = (
    AM_LDFLAGS      => '-Wl,--export-dynamic',
    AR              => 'ar',
    CC              => 'gcc',
    CFLAGS          => '-std=gnu11 -fpermissive -Wno-error -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=old-style-definition -Wno-error=return-type -Wno-implicit-int -Wno-error=strict-prototypes',
    CPP             => 'gcc -E',
    CPPFLAGS        => '',
    GUILE_CFLAGS    => '-I/usr/include/guile/3.0 -I/usr',
    GUILE_LIBS      => '-lguile-3.0 -lgc -lpthread -ldl',
    LDFLAGS         => '',
    LIBS            => '',
    USE_SYSTEM_GLOB => 'yes'
);

1;
