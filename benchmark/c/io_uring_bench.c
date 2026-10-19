// Native C io_uring benchmark (raw syscalls, no liburing).
//
// Measures the same three scenarios as the Dart benchmark:
//   1. NOP, queue depth 1
//   2. NOP, batch of 64
//   3. 4 KiB file read, queue depth 1
//
// It prints one JSON object on stdout.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef __NR_io_uring_setup
#define __NR_io_uring_setup 425
#endif
#ifndef __NR_io_uring_enter
#define __NR_io_uring_enter 426
#endif

#define IORING_OFF_SQ_RING 0ULL
#define IORING_OFF_CQ_RING 0x8000000ULL
#define IORING_OFF_SQES 0x10000000ULL

#define IORING_ENTER_GETEVENTS 1U
#define IORING_FEAT_SINGLE_MMAP 1U

#define IORING_OP_NOP 0U
#define IORING_OP_READ 22U

struct io_sqring_offsets {
  uint32_t head;
  uint32_t tail;
  uint32_t ring_mask;
  uint32_t ring_entries;
  uint32_t flags;
  uint32_t dropped;
  uint32_t array;
  uint32_t resv1;
  uint64_t resv2;
};

struct io_cqring_offsets {
  uint32_t head;
  uint32_t tail;
  uint32_t ring_mask;
  uint32_t ring_entries;
  uint32_t overflow;
  uint32_t cqes;
  uint32_t flags;
  uint32_t resv1;
  uint64_t resv2;
};

struct io_uring_params {
  uint32_t sq_entries;
  uint32_t cq_entries;
  uint32_t flags;
  uint32_t sq_thread_cpu;
  uint32_t sq_thread_idle;
  uint32_t features;
  uint32_t wq_fd;
  uint32_t resv[3];
  struct io_sqring_offsets sq_off;
  struct io_cqring_offsets cq_off;
};

struct io_uring_sqe {
  uint8_t opcode;
  uint8_t flags;
  uint16_t ioprio;
  int32_t fd;
  uint64_t off;
  uint64_t addr;
  uint32_t len;
  uint32_t op_flags;
  uint64_t user_data;
  uint16_t buf_index;
  uint16_t personality;
  int32_t splice_fd_in;
  uint64_t addr3;
  uint64_t pad2;
};

struct io_uring_cqe {
  uint64_t user_data;
  int32_t res;
  uint32_t flags;
};

_Static_assert(sizeof(struct io_uring_params) == 120, "params layout");
_Static_assert(sizeof(struct io_uring_sqe) == 64, "sqe layout");
_Static_assert(sizeof(struct io_uring_cqe) == 16, "cqe layout");

struct ring {
  int fd;
  void *sq_ring;
  void *cq_ring;
  void *sqes;
  size_t sq_ring_sz;
  size_t cq_ring_sz;
  size_t sqes_sz;
  struct io_uring_sqe *sqe_array;
  struct io_uring_cqe *cqe_array;
  uint32_t *sq_head;
  uint32_t *sq_tail;
  uint32_t *sq_mask;
  uint32_t *sq_entries;
  uint32_t *sq_array;
  uint32_t *cq_head;
  uint32_t *cq_tail;
  uint32_t *cq_mask;
  uint32_t sqe_tail;
  uint32_t published_tail;
};

struct stats {
  int operations;
  double total_ms;
  double us_per_op;
  double ops_per_sec;
};

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void ring_free(struct ring *r) {
  if (r->sqes != NULL && r->sqes != MAP_FAILED) {
    munmap(r->sqes, r->sqes_sz);
  }
  if (r->sq_ring != NULL && r->sq_ring != MAP_FAILED) {
    munmap(r->sq_ring, r->sq_ring_sz);
  }
  if (r->cq_ring != NULL && r->cq_ring != MAP_FAILED &&
      r->cq_ring != r->sq_ring) {
    munmap(r->cq_ring, r->cq_ring_sz);
  }
  if (r->fd >= 0) {
    close(r->fd);
  }
}

static int ring_init(struct ring *r, unsigned entries) {
  memset(r, 0, sizeof(*r));
  r->fd = -1;

  struct io_uring_params params;
  memset(&params, 0, sizeof(params));

  long fd = syscall(__NR_io_uring_setup, entries, &params);
  if (fd < 0) {
    fprintf(stderr, "io_uring_setup failed: %s\n", strerror(errno));
    return -1;
  }
  r->fd = (int)fd;

  size_t sq_ring_sz =
      params.sq_off.array + params.sq_entries * sizeof(uint32_t);
  size_t cq_ring_sz =
      params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe);
  int single_mmap = (params.features & IORING_FEAT_SINGLE_MMAP) != 0;

  if (single_mmap) {
    size_t ring_sz = sq_ring_sz > cq_ring_sz ? sq_ring_sz : cq_ring_sz;
    r->sq_ring = mmap(NULL, ring_sz, PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_SQ_RING);
    if (r->sq_ring == MAP_FAILED) {
      fprintf(stderr, "mmap(sq/cq ring) failed: %s\n", strerror(errno));
      ring_free(r);
      return -1;
    }
    r->cq_ring = r->sq_ring;
    r->sq_ring_sz = ring_sz;
    r->cq_ring_sz = ring_sz;
  } else {
    r->sq_ring = mmap(NULL, sq_ring_sz, PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_SQ_RING);
    if (r->sq_ring == MAP_FAILED) {
      fprintf(stderr, "mmap(sq ring) failed: %s\n", strerror(errno));
      ring_free(r);
      return -1;
    }
    r->cq_ring = mmap(NULL, cq_ring_sz, PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_CQ_RING);
    if (r->cq_ring == MAP_FAILED) {
      fprintf(stderr, "mmap(cq ring) failed: %s\n", strerror(errno));
      ring_free(r);
      return -1;
    }
    r->sq_ring_sz = sq_ring_sz;
    r->cq_ring_sz = cq_ring_sz;
  }

  r->sqes_sz = params.sq_entries * sizeof(struct io_uring_sqe);
  r->sqes = mmap(NULL, r->sqes_sz, PROT_READ | PROT_WRITE,
                 MAP_SHARED | MAP_POPULATE, r->fd, IORING_OFF_SQES);
  if (r->sqes == MAP_FAILED) {
    fprintf(stderr, "mmap(sqes) failed: %s\n", strerror(errno));
    ring_free(r);
    return -1;
  }

  r->sq_head = (uint32_t *)((char *)r->sq_ring + params.sq_off.head);
  r->sq_tail = (uint32_t *)((char *)r->sq_ring + params.sq_off.tail);
  r->sq_mask = (uint32_t *)((char *)r->sq_ring + params.sq_off.ring_mask);
  r->sq_entries =
      (uint32_t *)((char *)r->sq_ring + params.sq_off.ring_entries);
  r->sq_array = (uint32_t *)((char *)r->sq_ring + params.sq_off.array);
  r->cq_head = (uint32_t *)((char *)r->cq_ring + params.cq_off.head);
  r->cq_tail = (uint32_t *)((char *)r->cq_ring + params.cq_off.tail);
  r->cq_mask = (uint32_t *)((char *)r->cq_ring + params.cq_off.ring_mask);

  r->sqe_array = (struct io_uring_sqe *)r->sqes;
  r->cqe_array =
      (struct io_uring_cqe *)((char *)r->cq_ring + params.cq_off.cqes);

  for (uint32_t i = 0; i < params.sq_entries; i++) {
    r->sq_array[i] = i;
  }
  r->sqe_tail = *r->sq_tail;
  r->published_tail = r->sqe_tail;
  return 0;
}

static struct io_uring_sqe *next_sqe(struct ring *r) {
  uint32_t head = __atomic_load_n(r->sq_head, __ATOMIC_ACQUIRE);
  uint32_t entries = *r->sq_entries;
  if (r->sqe_tail - head >= entries) {
    return NULL;
  }
  struct io_uring_sqe *sqe = &r->sqe_array[r->sqe_tail & *r->sq_mask];
  memset(sqe, 0, sizeof(*sqe));
  r->sqe_tail++;
  return sqe;
}

static int ring_submit(struct ring *r, unsigned wait_nr) {
  uint32_t to_submit = r->sqe_tail - r->published_tail;
  __atomic_store_n(r->sq_tail, r->sqe_tail, __ATOMIC_RELEASE);
  r->published_tail = r->sqe_tail;

  unsigned flags = wait_nr > 0 ? IORING_ENTER_GETEVENTS : 0;
  long ret = syscall(__NR_io_uring_enter, r->fd, to_submit, wait_nr, flags,
                     NULL, 0);
  if (ret < 0) {
    fprintf(stderr, "io_uring_enter failed: %s\n", strerror(errno));
    return -1;
  }
  return (int)ret;
}

static int ring_wait_cqe(struct ring *r, struct io_uring_cqe *out) {
  for (;;) {
    uint32_t head = *r->cq_head;
    uint32_t tail = __atomic_load_n(r->cq_tail, __ATOMIC_ACQUIRE);
    if (head != tail) {
      *out = r->cqe_array[head & *r->cq_mask];
      __atomic_store_n(r->cq_head, head + 1, __ATOMIC_RELEASE);
      return 0;
    }
    long ret = syscall(__NR_io_uring_enter, r->fd, 0, 1, IORING_ENTER_GETEVENTS,
                       NULL, 0);
    if (ret < 0) {
      if (errno == EINTR) {
        continue;
      }
      fprintf(stderr, "io_uring_enter(wait) failed: %s\n", strerror(errno));
      return -1;
    }
  }
}

static int prep_nop(struct ring *r, uint64_t user_data) {
  struct io_uring_sqe *sqe = next_sqe(r);
  if (sqe == NULL) {
    return -1;
  }
  sqe->opcode = IORING_OP_NOP;
  sqe->fd = -1;
  sqe->user_data = user_data;
  return 0;
}

static int bench_nop_qd1(struct ring *r, int iterations, struct stats *out) {
  for (int i = 0; i < 100; i++) {
    if (prep_nop(r, (uint64_t)i) < 0 || ring_submit(r, 1) < 0) {
      return -1;
    }
    struct io_uring_cqe cqe;
    if (ring_wait_cqe(r, &cqe) < 0) {
      return -1;
    }
  }

  double started = now_seconds();
  for (int i = 0; i < iterations; i++) {
    if (prep_nop(r, (uint64_t)i) < 0 || ring_submit(r, 1) < 0) {
      return -1;
    }
    struct io_uring_cqe cqe;
    if (ring_wait_cqe(r, &cqe) < 0) {
      return -1;
    }
  }
  double total = now_seconds() - started;

  out->operations = iterations;
  out->total_ms = total * 1000.0;
  out->us_per_op = total * 1e6 / iterations;
  out->ops_per_sec = iterations / total;
  return 0;
}

static int bench_nop_batch(struct ring *r, int total_ops, struct stats *out) {
  const int batch = 64;
  int batches = total_ops / batch;
  if (batches < 1) {
    batches = 1;
  }

  for (int round = 0; round < 2; round++) {
    for (int i = 0; i < batch; i++) {
      if (prep_nop(r, (uint64_t)i) < 0) {
        return -1;
      }
    }
    if (ring_submit(r, batch) < 0) {
      return -1;
    }
    for (int i = 0; i < batch; i++) {
      struct io_uring_cqe cqe;
      if (ring_wait_cqe(r, &cqe) < 0) {
        return -1;
      }
    }
  }

  double started = now_seconds();
  for (int round = 0; round < batches; round++) {
    for (int i = 0; i < batch; i++) {
      if (prep_nop(r, (uint64_t)i) < 0) {
        return -1;
      }
    }
    if (ring_submit(r, batch) < 0) {
      return -1;
    }
    for (int i = 0; i < batch; i++) {
      struct io_uring_cqe cqe;
      if (ring_wait_cqe(r, &cqe) < 0) {
        return -1;
      }
    }
  }
  double total = now_seconds() - started;
  int operations = batches * batch;

  out->operations = operations;
  out->total_ms = total * 1000.0;
  out->us_per_op = total * 1e6 / operations;
  out->ops_per_sec = operations / total;
  return 0;
}

static int bench_read(struct ring *r, int fd, void *buffer, int buffer_size,
                      int iterations, struct stats *out, size_t *bytes_out) {
  const off_t file_size = 1024 * 1024;
  const int warmup = 8;

  for (int i = 0; i < warmup; i++) {
    struct io_uring_sqe *sqe = next_sqe(r);
    if (sqe == NULL) {
      return -1;
    }
    sqe->opcode = IORING_OP_READ;
    sqe->fd = fd;
    sqe->addr = (uint64_t)(uintptr_t)buffer;
    sqe->len = (uint32_t)buffer_size;
    sqe->off = (uint64_t)((i * buffer_size) % file_size);
    sqe->user_data = (uint64_t)i;
    if (ring_submit(r, 1) < 0) {
      return -1;
    }
    struct io_uring_cqe cqe;
    if (ring_wait_cqe(r, &cqe) < 0 || cqe.res < 0) {
      return -1;
    }
  }

  size_t bytes = 0;
  double started = now_seconds();
  for (int i = 0; i < iterations; i++) {
    struct io_uring_sqe *sqe = next_sqe(r);
    if (sqe == NULL) {
      return -1;
    }
    sqe->opcode = IORING_OP_READ;
    sqe->fd = fd;
    sqe->addr = (uint64_t)(uintptr_t)buffer;
    sqe->len = (uint32_t)buffer_size;
    sqe->off = (uint64_t)(((int64_t)i * buffer_size) % file_size);
    sqe->user_data = (uint64_t)i;
    if (ring_submit(r, 1) < 0) {
      return -1;
    }
    struct io_uring_cqe cqe;
    if (ring_wait_cqe(r, &cqe) < 0 || cqe.res < 0) {
      return -1;
    }
    bytes += (size_t)cqe.res;
  }
  double total = now_seconds() - started;

  out->operations = iterations;
  out->total_ms = total * 1000.0;
  out->us_per_op = total * 1e6 / iterations;
  out->ops_per_sec = iterations / total;
  *bytes_out = bytes;
  return 0;
}

int main(int argc, char **argv) {
  int qd1_iterations = 2000;
  int batch_ops = 100000;
  int read_iterations = 256;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--qd1") == 0 && i + 1 < argc) {
      qd1_iterations = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--batch-ops") == 0 && i + 1 < argc) {
      batch_ops = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--reads") == 0 && i + 1 < argc) {
      read_iterations = atoi(argv[++i]);
    }
  }

  struct ring ring;
  if (ring_init(&ring, 256) < 0) {
    return 1;
  }

  struct stats nop_qd1;
  struct stats nop_batch;
  struct stats read_qd1;
  size_t read_bytes = 0;

  if (bench_nop_qd1(&ring, qd1_iterations, &nop_qd1) < 0 ||
      bench_nop_batch(&ring, batch_ops, &nop_batch) < 0) {
    ring_free(&ring);
    return 1;
  }

  char path[256];
  snprintf(path, sizeof(path), "/tmp/io_uring_bench_%d.bin", (int)getpid());
  int create_fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (create_fd < 0 || ftruncate(create_fd, 1024 * 1024) < 0) {
    fprintf(stderr, "failed to create benchmark file: %s\n", strerror(errno));
    if (create_fd >= 0) {
      close(create_fd);
    }
    ring_free(&ring);
    return 1;
  }
  close(create_fd);

  int read_fd = open(path, O_RDONLY);
  if (read_fd < 0) {
    fprintf(stderr, "failed to open benchmark file: %s\n", strerror(errno));
    unlink(path);
    ring_free(&ring);
    return 1;
  }

  void *buffer = malloc(4096);
  if (buffer == NULL ||
      bench_read(&ring, read_fd, buffer, 4096, read_iterations, &read_qd1,
                 &read_bytes) < 0) {
    fprintf(stderr, "file read benchmark failed\n");
    free(buffer);
    close(read_fd);
    unlink(path);
    ring_free(&ring);
    return 1;
  }

  double read_mib = (double)read_bytes / (1024.0 * 1024.0);
  double read_seconds = read_qd1.total_ms / 1000.0;
  double read_mib_per_sec = read_seconds > 0 ? read_mib / read_seconds : 0;

#if defined(__x86_64__)
  const char *arch = "x86_64";
#elif defined(__aarch64__)
  const char *arch = "aarch64";
#else
  const char *arch = "unknown";
#endif

  printf(
      "{\"arch\":\"%s\","
      "\"nopQd1\":{\"operations\":%d,\"totalMs\":%.3f,\"usPerOp\":%.3f,"
      "\"opsPerSec\":%.1f},"
      "\"nopBatch64\":{\"batchSize\":64,\"operations\":%d,\"totalMs\":%.3f,"
      "\"usPerOp\":%.3f,\"opsPerSec\":%.1f},"
      "\"fileRead4kQd1\":{\"operations\":%d,\"bytes\":%zu,\"totalMs\":%.3f,"
      "\"usPerOp\":%.3f,\"opsPerSec\":%.1f,\"mibPerSec\":%.2f}}\n",
      arch, nop_qd1.operations, nop_qd1.total_ms, nop_qd1.us_per_op,
      nop_qd1.ops_per_sec, nop_batch.operations, nop_batch.total_ms,
      nop_batch.us_per_op, nop_batch.ops_per_sec, read_qd1.operations,
      read_bytes, read_qd1.total_ms, read_qd1.us_per_op, read_qd1.ops_per_sec,
      read_mib_per_sec);

  free(buffer);
  close(read_fd);
  unlink(path);
  ring_free(&ring);
  return 0;
}
