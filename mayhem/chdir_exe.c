/*
 * nDPI's harnesses read their data files (protos.txt, lists/, ...) from
 * dirname(argv[0]) and a few from the cwd. Pin both to the staged data dir
 * before main(), keeping every other path argument usable from the old cwd.
 */
#define _GNU_SOURCE
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef MAYHEM_DATA_DIR
#error "MAYHEM_DATA_DIR must be defined"
#endif

static char *absolutize(const char *p) {
  char buf[PATH_MAX];
  return realpath(p, buf) ? strdup(buf) : NULL;
}

__attribute__((constructor)) static void pin_data_dir(int argc, char **argv, char **envp) {
  int i;
  const char *base;
  char *fixed;
  size_t n;
  (void)envp;

  for(i = 1; i < argc; i++) {
    const char *eq = argv[i][0] == '-' ? strchr(argv[i], '=') : NULL;
    if(argv[i][0] == '-' && !eq) continue;
    fixed = absolutize(eq ? eq + 1 : argv[i]);
    if(!fixed) continue;
    if(eq) {
      n = (size_t)(eq + 1 - argv[i]);
      char *joined = malloc(n + strlen(fixed) + 1);
      if(!joined) continue;
      memcpy(joined, argv[i], n);
      strcpy(joined + n, fixed);
      free(fixed);
      fixed = joined;
    }
    argv[i] = fixed;
  }

  base = strrchr(argv[0], '/');
  base = base ? base + 1 : argv[0];
  n = strlen(MAYHEM_DATA_DIR) + 1 + strlen(base) + 1;
  fixed = malloc(n);
  if(fixed) {
    strcpy(fixed, MAYHEM_DATA_DIR);
    strcat(fixed, "/");
    strcat(fixed, base);
    argv[0] = fixed;
  }
  if(chdir(MAYHEM_DATA_DIR) != 0) { /* data dir absent: leave cwd alone */ }
}
