# Local TLS regression fixture

The certificate and private key in this directory are public test fixtures for
the reserved `never-resolve.invalid` hostname. They are not used by production
code. Tests explicitly trust this certificate in a separate SecurityContext;
normal application connections continue to use the platform trust store.

The tests cover successful TLS through SOCKS5, wrong-host rejection, untrusted
certificate rejection, and cancellation during an unfinished TLS handshake.
