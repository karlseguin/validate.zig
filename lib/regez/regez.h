#include <stdint.h>
#include <stdalign.h>
#include <regex.h>
#include <stdbool.h>

size_t sizeof_regex_t() {
	return sizeof(regex_t);
}

uint16_t alignof_regex_t() {
	return alignof(regex_t);
}

bool isMatch(regex_t *re, char const *input) {
	regmatch_t pmatch[0];
	return regexec(re, input, 0, pmatch, 0) == 0;
}

// regex_t *init(char const *pattern) {
// 	regex_t *re;
// 	re = (regex_t *) malloc(sizeof(regex_t));
// 	if (regcomp(re, pattern, REG_EXTENDED | REG_NOSUB)) {
// 		free(re);
// 		return NULL;
// 	}
// 	return re;
// }



// void deinit(regex_t *re) {
// 	free(re);
// }
