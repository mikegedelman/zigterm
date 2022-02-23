// @cInclude("util.h");
//     @cInclude("unistd.h");
//     @cInclude("sys/ioctl.h");
//     @cInclude("sys/select.h");
//     @cInclude("fcntl.h");

#include <util.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <fcntl.h>


int tty_setup(const char* cmd) {
	int amaster;
	char fname[256];

    int pid = forkpty(&amaster, fname, NULL, NULL);
    // std.debug.print("pid: {}\namaster: {}\nfname: {s}\n", .{ pid, amaster, fname });

    if (pid == 0) {
        close(amaster);
        setsid();

        int slave_fd = open(fname, O_RDWR | O_NOCTTY);

        // error: TODO: support C ABI for more targets. https://github.com/ziglang/zig/issues/1481
        ioctl(slave_fd, TIOCSCTTY, NULL);

        dup2(slave_fd, 0);
        dup2(slave_fd, 1);
        dup2(slave_fd, 2);

        char *env[] = { "TERM=dumb", NULL };

        execle("/bin/sh", "/bin/sh", (char*) NULL, env);

        return slave_fd;
        // std.debug.print("there\n", .{});
    }

    // Set the master fd to non-blocking mode.
    fcntl(amaster, F_SETFL, (fcntl(amaster, F_GETFL) | O_NONBLOCK));
    return amaster;
}