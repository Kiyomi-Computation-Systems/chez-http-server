/* The lost close (chez-websocket's decision 0008, item 6), the client's side.
 *
 * Each run connects to 127.0.0.1:PORT, asks for a WebSocket upgrade, and reads
 * the 101.  Then one thread sends TOTAL bytes in CHUNK-byte writes (zeros: a
 * stand-in for a message's payload), while another reads to the stream's end;
 * or, with MODE `serial`, one thread sends them all and then reads, as a
 * client whose one thread is busy sending reads nothing until its send stops.
 * Once both have stopped, the client closes, as a WebSocket client does once
 * the server's TCP close comes (RFC 6455 §7.1.1).
 *
 * Per run it prints whether the close frame (88 02 03 f1) was read after the
 * 101, how the reading ended (eof or the errno), how the sending ended (done
 * or the errno), the bytes sent, and the milliseconds from the first send to
 * the reading's end.  The last line is a tally.
 *
 *   cc -O2 -pthread -o client taker-close-client.c
 *   ./client PORT RUNS TOTAL CHUNK [serial]
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static const unsigned char marker[4] = {0x88, 0x02, 0x03, 0xf1};
static const char handshake[] =
    "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

struct run {
  int fd;
  long total, chunk;
  long sent;
  int send_errno;              /* 0: all sent */
  int read_errno;              /* 0: eof */
  int saw_marker;
  unsigned char tail[3];       /* the last bytes read, for a marker split across reads */
  int tail_len;
  double t0, t_end;
};

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void scan(struct run *r, const unsigned char *b, long n) {
  unsigned char joined[3 + 65536];
  long m;
  if (r->saw_marker || n <= 0) return;
  memcpy(joined, r->tail, r->tail_len);
  memcpy(joined + r->tail_len, b, n);
  m = r->tail_len + n;
  for (long i = 0; i + 4 <= m; i++)
    if (memcmp(joined + i, marker, 4) == 0) { r->saw_marker = 1; return; }
  r->tail_len = m < 3 ? (int)m : 3;
  memcpy(r->tail, joined + m - r->tail_len, r->tail_len);
}

static void *sender(void *arg) {
  struct run *r = arg;
  static unsigned char zeros[1 << 20];
  r->t0 = now_ms();
  while (r->sent < r->total) {
    long want = r->total - r->sent < r->chunk ? r->total - r->sent : r->chunk;
    ssize_t k = send(r->fd, zeros, want, 0);
    if (k < 0) { if (errno == EINTR) continue; r->send_errno = errno; break; }
    r->sent += k;
  }
  return NULL;
}

static void *reader(void *arg) {
  struct run *r = arg;
  unsigned char b[65536];
  for (;;) {
    ssize_t k = recv(r->fd, b, sizeof b, 0);
    if (k > 0) { scan(r, b, k); continue; }
    if (k == 0) { r->read_errno = 0; break; }
    if (errno == EINTR) continue;
    r->read_errno = errno;
    break;
  }
  r->t_end = now_ms();
  return NULL;
}

static const char *ename(int e) {
  switch (e) {
  case 0: return "-";
  case EPIPE: return "EPIPE";
  case ECONNRESET: return "ECONNRESET";
  default: return strerror(e);
  }
}

int main(int argc, char **argv) {
  int port, runs;
  long total, chunk;
  int marker_read = 0, read_eof = 0, read_reset = 0, send_done = 0, serial;
  if (argc != 5 && argc != 6) { fprintf(stderr, "usage: %s PORT RUNS TOTAL CHUNK [serial]\n", argv[0]); return 2; }
  serial = argc == 6 && strcmp(argv[5], "serial") == 0;
  port = atoi(argv[1]); runs = atoi(argv[2]); total = atol(argv[3]); chunk = atol(argv[4]);
  if (chunk > (1 << 20)) chunk = 1 << 20;
  signal(SIGPIPE, SIG_IGN);
  for (int i = 0; i < runs; i++) {
    struct run r;
    struct sockaddr_in a;
    char head[4096];
    long got = 0;
    pthread_t ts, tr;
    memset(&r, 0, sizeof r);
    r.total = total; r.chunk = chunk;
    r.fd = socket(AF_INET, SOCK_STREAM, 0);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(r.fd, (struct sockaddr *)&a, sizeof a) != 0) { perror("connect"); return 2; }
    if (send(r.fd, handshake, sizeof handshake - 1, 0) != (ssize_t)(sizeof handshake - 1)) { perror("send"); return 2; }
    /* the 101, to its blank line; the server writes nothing after it until it fails */
    for (;;) {
      ssize_t k = recv(r.fd, head + got, sizeof head - 1 - got, 0);
      if (k <= 0) { fprintf(stderr, "run %d: no 101\n", i); return 2; }
      got += k; head[got] = 0;
      if (strstr(head, "\r\n\r\n")) break;
    }
    if (strncmp(head, "HTTP/1.1 101", 12) != 0) { fprintf(stderr, "run %d: %.40s\n", i, head); return 2; }
    {
      char *body = strstr(head, "\r\n\r\n") + 4;
      scan(&r, (unsigned char *)body, got - (body - head));
    }
    if (serial) {
      sender(&r);
      reader(&r);
    } else {
      pthread_create(&tr, NULL, reader, &r);
      pthread_create(&ts, NULL, sender, &r);
      pthread_join(ts, NULL);
      pthread_join(tr, NULL);
    }
    close(r.fd);
    printf("run %d: close-frame %s, read %s, send %s, sent %ld, %.1f ms\n", i,
           r.saw_marker ? "read" : "lost", ename(r.read_errno), ename(r.send_errno), r.sent,
           r.t_end - r.t0);
    marker_read += r.saw_marker;
    read_eof += r.read_errno == 0;
    read_reset += r.read_errno == ECONNRESET;
    send_done += r.send_errno == 0;
  }
  printf("tally: %d runs, close frame read %d, read ended eof %d, reset %d, all sent %d\n",
         runs, marker_read, read_eof, read_reset, send_done);
  return 0;
}
