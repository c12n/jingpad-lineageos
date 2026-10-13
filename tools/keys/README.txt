testkey_rsa4096.pem is the public AOSP test key from external/avb/test/data
(also bundled in the JingPad unlock tool). Anyone can sign with it, which is
fine on an unlocked bootloader. Generate your own with
  openssl genrsa -out mykey.pem 4096
and pass --key / --chain-key boot=mykey.pem if you prefer.
