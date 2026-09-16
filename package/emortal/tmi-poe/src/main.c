/* SPDX-License-Identifier: GPL-2.0-only */
#define _GNU_SOURCE
#include "tmi.h"

#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <limits.h>
#include <linux/gpio.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <syslog.h>
#include <time.h>
#include <uci.h>
#include <unistd.h>

#define LOCK_FILE "/var/lock/tmi-poe.lock"
#define OWNER_FILE "/var/lock/tmi-poe.owner"
#define I2C_NODE "/sys/firmware/devicetree/base/soc@0/i2c@78b5000"
#define I2C_ADAPTERS "/sys/bus/i2c/devices"

static volatile sig_atomic_t stopping, reloading;

struct transport {
	int fd;
	unsigned int address;
	bool cleaning;
	char device[32];
};

static void delay_ms(void *ctx, unsigned int ms)
{
	struct timespec t = { .tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000L };
	struct transport *bus = ctx;

	while (nanosleep(&t, &t) && errno == EINTR)
		if (stopping && !bus->cleaning)
			break;
}

static int transfer(struct transport *bus, struct i2c_msg *msgs, int count,
		    bool retry)
{
	struct i2c_rdwr_ioctl_data request = { .msgs = msgs, .nmsgs = count };
	unsigned int attempt;
	int ret, error;

	for (attempt = 0; attempt < (retry ? 3U : 1U); attempt++) {
		if (stopping && !bus->cleaning)
			return -ECANCELED;
		ret = ioctl(bus->fd, I2C_RDWR, &request);
		if (ret == count)
			return 0;
		error = ret < 0 ? errno : EIO;
		if (error != EINTR && error != EAGAIN && error != EIO &&
		    error != EREMOTEIO && error != ETIMEDOUT)
			return -error;
		if (retry && attempt < 2)
			delay_ms(bus, 20);
	}
	return -error;
}

static int read_reg(void *ctx, uint8_t reg, uint8_t *value)
{
	struct transport *bus = ctx;
	uint8_t result = 0;
	struct i2c_msg msgs[2] = {
		{ .addr = bus->address, .len = 1, .buf = &reg },
		{ .addr = bus->address, .flags = I2C_M_RD, .len = 1, .buf = &result },
	};
	int ret = transfer(bus, msgs, 2, true);

	if (!ret)
		*value = result;
	return ret;
}

static int write_reg(void *ctx, uint8_t reg, uint8_t value)
{
	struct transport *bus = ctx;
	uint8_t data[2] = { reg, value };
	struct i2c_msg msg = { .addr = bus->address, .len = 2, .buf = data };

	/* A failed command may already have reached the chip. Never replay it. */
	return transfer(bus, &msg, 1, false);
}

static const struct tmi_board *get_board(void)
{
	char names[512];
	ssize_t size;
	size_t offset, i;
	int fd = open("/sys/firmware/devicetree/base/compatible", O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		return NULL;
	size = read(fd, names, sizeof(names));
	close(fd);
	if (size <= 0 || names[size - 1] != '\0')
		return NULL;
	for (offset = 0; offset < (size_t)size; offset += strlen(names + offset) + 1)
		for (i = 0; i < 2; i++)
			if (!strcmp(names + offset, tmi_boards[i].compatible))
				return &tmi_boards[i];
	return NULL;
}

static int open_bus(const struct tmi_board *board, struct tmi_io *io)
{
	struct transport *bus = io->ctx;
	glob_t paths = { 0 };
	char resolved[PATH_MAX], node[PATH_MAX];
	size_t i;
	unsigned long funcs;
	int fd = -ENODEV, candidate, ret, number, used;

	io->stage = "i2c-node";
	if (!realpath(I2C_NODE, node))
		return -errno;
	io->stage = "i2c-enumerate";
	ret = glob(I2C_ADAPTERS "/i2c-*/of_node", 0, NULL, &paths);
	if (ret) {
		globfree(&paths);
		return ret == GLOB_NOSPACE ? -ENOMEM : ret == GLOB_NOMATCH ? -ENODEV : -EIO;
	}
	io->stage = "i2c-match";
	for (i = 0; i < paths.gl_pathc; i++) {
		if (!realpath(paths.gl_pathv[i], resolved) || strcmp(resolved, node))
			continue;
		used = 0;
		if (sscanf(paths.gl_pathv[i], I2C_ADAPTERS "/i2c-%d/of_node%n",
			   &number, &used) != 1 || !used || paths.gl_pathv[i][used] || number < 0)
			continue;
		snprintf(bus->device, sizeof(bus->device), "/dev/i2c-%d", number);
		io->stage = "i2c-open";
		candidate = open(bus->device, O_RDWR | O_CLOEXEC);
		if (candidate < 0) {
			fd = -errno;
			break;
		}
		io->stage = "i2c-capabilities";
		if (ioctl(candidate, I2C_FUNCS, &funcs) < 0) {
			fd = -errno;
			close(candidate);
			break;
		}
		if (!(funcs & I2C_FUNC_I2C)) {
			fd = -EOPNOTSUPP;
			close(candidate);
			break;
		}
		/* Respect a future kernel driver's ownership; never I2C_SLAVE_FORCE. */
		io->stage = "i2c-address";
		if (ioctl(candidate, I2C_SLAVE, board->address) < 0) {
			fd = -errno;
			close(candidate);
			break;
		}
		fd = candidate;
		break;
	}
	globfree(&paths);
	return fd;
}

static int request_reset(void)
{
	glob_t paths = { 0 };
	struct gpiochip_info chip;
	struct gpio_v2_line_info line;
	struct gpio_v2_line_request request = { 0 };
	size_t i;
	int ret = -ENODEV, fd;

	if (glob("/dev/gpiochip*", 0, NULL, &paths)) {
		globfree(&paths);
		return -ENODEV;
	}
	for (i = 0; i < paths.gl_pathc; i++) {
		fd = open(paths.gl_pathv[i], O_RDONLY | O_CLOEXEC);
		if (fd < 0)
			continue;
		memset(&chip, 0, sizeof(chip));
		memset(&line, 0, sizeof(line));
		line.offset = 45;
		if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &chip) < 0 || chip.lines != 53 ||
		    strcmp(chip.label, "1000000.pinctrl") ||
		    ioctl(fd, GPIO_V2_GET_LINEINFO_IOCTL, &line) < 0 ||
		    strcmp(line.name, "poe-reset")) {
			close(fd);
			continue;
		}
		request.offsets[0] = line.offset;
		request.num_lines = 1;
		strcpy(request.consumer, "tmi-poe");
		request.config.flags = GPIO_V2_LINE_FLAG_OUTPUT | GPIO_V2_LINE_FLAG_ACTIVE_LOW;
		/* Logical 0 releases active-low reset; no global GPIO number. */
		if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &request) < 0)
			ret = -errno;
		else
			ret = request.fd;
		close(fd);
		break;
	}
	globfree(&paths);
	return ret;
}

static int reset_value(int fd, bool asserted)
{
	struct gpio_v2_line_values values = { .bits = asserted, .mask = 1 };

	return ioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &values) < 0 ? -errno : 0;
}

static int load_policy(const struct tmi_board *board, struct tmi_policy *policy,
		       bool *enabled)
{
	struct uci_context *ctx = uci_alloc_context();
	struct uci_package *package = NULL;
	struct uci_section *section;
	struct uci_option *disabled, *option;
	struct uci_element *element;
	const char *s;
	char *end;
	unsigned long value;
	unsigned int port;
	int ret = -EINVAL;

	if (!ctx)
		return -ENOMEM;
	if (uci_load(ctx, "tmi-poe", &package))
		goto out;
	section = uci_lookup_section(ctx, package, "main");
	if (!section || strcmp(section->type, "poe"))
		goto out;
	policy->budget_mw = board->max_budget_mw;
	policy->mask = tmi_board_mask(board);
	policy->class4plus = true;
	*enabled = true;
	option = uci_lookup_option(ctx, section, "enabled");
	if (option && option->type != UCI_TYPE_STRING)
		goto out;
	s = option ? option->v.string : NULL;
	if (s) {
		if (strcmp(s, "0") && strcmp(s, "1"))
			goto out;
		*enabled = !strcmp(s, "1");
	}
	option = uci_lookup_option(ctx, section, "budget_mw");
	if (option && option->type != UCI_TYPE_STRING)
		goto out;
	s = option ? option->v.string : NULL;
	if (s) {
		errno = 0;
		value = strtoul(s, &end, 10);
		if (errno || *s < '0' || *s > '9' || *end ||
		    value > board->max_budget_mw || value < 1000)
			goto out;
		policy->budget_mw = value;
	}
	option = uci_lookup_option(ctx, section, "class4plus");
	if (option) {
		if (option->type != UCI_TYPE_STRING ||
		    (strcmp(option->v.string, "0") && strcmp(option->v.string, "1")))
			goto out;
		policy->class4plus = !strcmp(option->v.string, "1");
	}
	disabled = uci_lookup_option(ctx, section, "disabled_ports");
	if (disabled) {
		if (disabled->type != UCI_TYPE_LIST)
			goto out;
		uci_foreach_element(&disabled->v.list, element) {
			s = element->name;
			if (strlen(s) != 4 || memcmp(s, "lan", 3) || s[3] < '1' || s[3] > '7')
				goto out;
			port = s[3] - '1';
			if (port >= board->ports)
				goto out;
			policy->mask &= ~(1U << (board->port_map[port] - 1));
		}
	}
	if (!*enabled)
		policy->mask = 0;
	ret = tmi_validate(board, policy);
out:
	uci_free_context(ctx);
	return ret;
}

static int lock_file(const char *path, int operation)
{
	int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	int error;

	if (fd < 0)
		return -errno;
	if (flock(fd, operation) == 0)
		return fd;
	error = errno;
	close(fd);
	return -error;
}

static void signal_handler(int signal)
{
	if (signal == SIGHUP)
		reloading = 1;
	else
		stopping = 1;
}

static void error_log(const struct tmi_io *io, const struct tmi_board *board, int ret)
{
	const struct transport *bus = io->ctx;

	if (!strncmp(io->stage, "i2c-", 4))
		syslog(LOG_ERR, "stage=%s failed: board=%s address=0x%02x node=%s "
		       "adapters=%s device=%s errno=%d (%s)", io->stage, board->compatible,
		       board->address, I2C_NODE, I2C_ADAPTERS,
		       *bus->device ? bus->device : "unmatched", -ret, strerror(-ret));
	else if (io->failed_reg < 0)
		syslog(LOG_ERR, "stage=%s failed: errno=%d (%s)",
		       io->stage, -ret, strerror(-ret));
	else if (io->operation && !strcmp(io->operation, "verify"))
		syslog(LOG_ERR, "stage=%s failed: operation=verify register=0x%02x "
		       "expected=0x%02x actual=0x%02x errno=%d (%s)", io->stage,
		       io->failed_reg, io->expected, io->actual, -ret, strerror(-ret));
	else
		syslog(LOG_ERR, "stage=%s failed: operation=%s last-register=0x%02x errno=%d (%s)",
		       io->stage, io->operation, io->failed_reg, -ret, strerror(-ret));
}

static unsigned int nominal_budget_mw(const struct tmi_status *status)
{
	/* Inverse of the factory 53 V threshold encoding, subject to quantization. */
	return (uint64_t)status->budget_raw * 1956U * 53U / 1000U;
}

static void print_status(const struct tmi_board *board, const struct tmi_policy *policy,
			 const struct tmi_status *status)
{
	static const char * const mode_names[] = { "shutdown", "manual", "semi", "auto" };
	unsigned int port, channel, index, mode;

	printf("chip=%s address=0x%02x requested-mask=0x%02x requested-budget-mw=%u requested-class4plus=%u "
	       "input-mv=%u summary=0x%02x powered=0x%02x good=0x%02x\n", board->chip,
	       board->address, policy->mask, policy->budget_mw, policy->class4plus, status->input_mv,
	       status->summary, status->powered, status->good);
	printf("hw-budget-raw=0x%04x hw-budget-nominal-mw=%u hw-detect=0x%02x hw-classify=0x%02x hw-class4plus=0x%02x\n",
	       status->budget_raw, nominal_budget_mw(status), status->detect, status->classify,
	       status->class4plus);
	for (port = 0; port < board->ports; port++) {
		channel = board->port_map[port];
		index = channel - 1;
		mode = (status->modes[index / 4] >> (2 * (index % 4))) & 3;
		printf("lan%u pse=%u requested=%u mode=%s powered=%u good=%u state=0x%02x "
		       "voltage-mv=%u ", port + 1,
		       channel, !!(policy->mask & (1U << (channel - 1))),
		       mode_names[mode], !!(status->powered & (1U << index)),
		       !!(status->good & (1U << index)), status->port_state[port],
		       status->voltage_mv[port]);
		if (status->class4plus & (1U << index))
			printf("current-raw=0x%04x current-scale=unresolved current-ma-at-1a=%u "
			       "current-ma-at-2a=%u\n", status->current_raw[port],
			       status->current_ma[port], status->current_raw[port] * 3912U / 16000U);
		else
			printf("current-ma=%u power-mw=%llu\n", status->current_ma[port],
			       (unsigned long long)status->voltage_mv[port] * status->current_ma[port] / 1000);
	}
}

static void log_changes(const struct tmi_board *board, const struct tmi_status *old,
			const struct tmi_status *now, bool first)
{
	unsigned int port, channel, bit, event;

	if (first || memcmp(old->modes, now->modes, sizeof(now->modes)) ||
	    old->detect != now->detect || old->classify != now->classify ||
	    old->budget_raw != now->budget_raw || old->class4plus != now->class4plus)
		syslog(LOG_INFO, "hardware configuration: modes=0x%02x/0x%02x detect=0x%02x "
		       "classify=0x%02x class4plus=0x%02x budget-raw=0x%04x budget-nominal-mw=%u",
		       now->modes[0], now->modes[1], now->detect, now->classify,
		       now->class4plus, now->budget_raw, nominal_budget_mw(now));
	if (first || old->summary != now->summary || old->good != now->good ||
	    old->powered != now->powered)
		syslog(LOG_INFO, "controller status: summary=0x%02x input-mv=%u powered=0x%02x good=0x%02x",
		       now->summary, now->input_mv, now->powered, now->good);
	for (event = 0; event < TMI_EVENTS; event++)
		if (first || old->events[event] != now->events[event])
			syslog(LOG_INFO, "controller event: register=0x%02x value=0x%02x",
			       0x02 + 2 * event, now->events[event]);
	for (port = 0; port < board->ports; port++) {
		channel = board->port_map[port];
		bit = 1U << (channel - 1);
		if (first || ((old->powered ^ now->powered) & bit) ||
		    ((old->good ^ now->good) & bit) ||
		    old->port_state[port] != now->port_state[port]) {
			syslog(LOG_INFO, "port status: lan%u pse=%u powered=%u good=%u state=0x%02x "
			       "voltage-mv=%u current-raw=0x%04x current-scale=%s", port + 1, channel,
			       !!(now->powered & bit), !!(now->good & bit), now->port_state[port],
			       now->voltage_mv[port], now->current_raw[port],
			       (now->class4plus & bit) ? "unresolved" : "1a");
		}
	}
}

int main(int argc, char **argv)
{
	const struct tmi_board *board;
	struct tmi_policy policy, next;
	struct tmi_status status, previous = { 0 };
	struct transport bus = { .fd = -1 };
	struct tmi_io io = { .ctx = &bus, .read = read_reg, .write = write_reg,
		.delay = delay_ms, .stage = "startup", .failed_reg = -1 };
	struct sigaction action = { .sa_handler = signal_handler };
	bool run, enabled, initialized = false, first = true;
	int owner = -1, lock = -1, gpio = -1, ret = 0, cleanup, errors = 0;

	if (argc != 2 || (strcmp(argv[1], "run") && strcmp(argv[1], "status"))) {
		fprintf(stderr, "Usage: tmi-poe {run|status}\n");
		return 2;
	}
	run = !strcmp(argv[1], "run");
	openlog("tmi-poe", LOG_PID | (run ? 0 : LOG_PERROR), LOG_DAEMON);
	board = get_board();
	if (!board) {
		syslog(LOG_ERR, "unsupported board; no hardware access");
		return 1;
	}
	ret = load_policy(board, &policy, &enabled);
	if (ret) {
		syslog(LOG_ERR, "configuration invalid; no hardware access");
		return 1;
	}
	if (run && !enabled) {
		syslog(LOG_INFO, "PoE disabled by configuration");
		return 0;
	}
	bus.address = board->address;
	if (run) {
		owner = lock_file(OWNER_FILE, LOCK_EX | LOCK_NB);
		if (owner < 0) {
			syslog(LOG_ERR, "another controller owns PoE or owner lock unavailable: %s",
			       strerror(-owner));
			return 1;
		}
		sigemptyset(&action.sa_mask);
		sigaction(SIGTERM, &action, NULL);
		sigaction(SIGINT, &action, NULL);
		sigaction(SIGHUP, &action, NULL);
		syslog(LOG_INFO, "initialization started: chip=%s address=0x%02x mask=0x%02x budget-mw=%u class4plus=%u",
		       board->chip, board->address, policy.mask, policy.budget_mw, policy.class4plus);
	}
	lock = lock_file(LOCK_FILE, run ? LOCK_EX : LOCK_SH);
	if (lock < 0) {
		ret = lock;
		io.stage = "lock";
		goto out;
	}
	bus.fd = open_bus(board, &io);
	if (bus.fd < 0) {
		ret = bus.fd;
		goto out;
	}
	if (!run) {
		ret = tmi_read_status(&io, board, &status);
		if (!ret)
			print_status(board, &policy, &status);
		goto out;
	}
	syslog(LOG_INFO, "I2C ready: device=%s node=%s address=0x%02x",
	       bus.device, I2C_NODE, board->address);
	io.stage = "gpio-request";
	gpio = request_reset();
	if (gpio < 0) {
		ret = gpio;
		goto out;
	}
	io.stage = "hardware-reset";
	ret = reset_value(gpio, true);
	if (ret)
		goto out;
	delay_ms(&bus, 200);
	ret = reset_value(gpio, false);
	if (ret)
		goto out;
	delay_ms(&bus, 100);
	syslog(LOG_INFO, "hardware reset completed: line=poe-reset hold-ms=200");
	initialized = true; /* Cleanup required even if a later initialization step fails. */
	ret = tmi_initialize(&io, board, &policy);
	if (ret)
		goto out;
	syslog(LOG_INFO, "initialization completed: configuration verified; PD detection requested mask=0x%02x",
	       policy.mask);
	flock(lock, LOCK_UN);
	while (!stopping) {
		io.failed_reg = -1;
		if (reloading) {
			reloading = 0;
			ret = load_policy(board, &next, &enabled);
			if (ret) {
				syslog(LOG_ERR, "reload rejected: invalid configuration; previous policy retained");
				ret = 0;
			} else {
				if (flock(lock, LOCK_EX) < 0) {
					ret = -errno;
					io.stage = "reload-lock";
					goto out;
				}
				syslog(LOG_INFO, "policy update started: mask=0x%02x budget-mw=%u class4plus=%u",
				       next.mask, next.budget_mw, next.class4plus);
				ret = tmi_set_policy(&io, board, &policy, &next);
				if (ret)
					goto out;
				policy = next;
				syslog(LOG_INFO, "policy update completed: mask=0x%02x budget-mw=%u class4plus=%u",
				       policy.mask, policy.budget_mw, policy.class4plus);
				flock(lock, LOCK_UN);
			}
		}
		if (flock(lock, LOCK_SH) < 0) {
			ret = -errno;
			io.stage = "status-lock";
			io.failed_reg = -1;
			goto out;
		}
		ret = tmi_read_status(&io, board, &status);
		flock(lock, LOCK_UN);
		if (ret) {
			if (!errors)
				error_log(&io, board, ret);
			if (++errors >= 3)
				goto out;
		} else {
			if (errors)
				syslog(LOG_NOTICE, "status communication recovered after %d failed samples", errors);
			errors = 0;
			if (status.input_mv < TMI_INPUT_MIN_MV || status.input_mv > TMI_INPUT_MAX_MV) {
				syslog(LOG_ERR, "supply outside board range: input-mv=%u; disabling PoE", status.input_mv);
				io.stage = "supply-monitor";
				io.failed_reg = -1;
				ret = -ERANGE;
				goto out;
			}
			log_changes(board, &previous, &status, first);
			previous = status;
			first = false;
		}
		poll(NULL, 0, 2000);
	}
	ret = 0;
out:
	if (ret)
		error_log(&io, board, ret);
	if (run && initialized) {
		bus.cleaning = true;
		syslog(LOG_INFO, "shutdown started");
		if (flock(lock, LOCK_EX) < 0) {
			cleanup = -errno;
			io.stage = "shutdown-lock";
			io.failed_reg = -1;
		} else {
			cleanup = tmi_disable(&io, board);
		}
		if (cleanup) {
			error_log(&io, board, cleanup);
			if (!ret)
				ret = cleanup;
		} else {
			syslog(LOG_INFO, "shutdown completed: all board PoE ports report off");
		}
	}
	if (gpio >= 0)
		close(gpio);
	if (bus.fd >= 0)
		close(bus.fd);
	if (lock >= 0)
		close(lock);
	if (owner >= 0)
		close(owner);
	closelog();
	return ret ? 1 : 0;
}
