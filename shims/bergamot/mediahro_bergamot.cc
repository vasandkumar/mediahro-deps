// C API over the Bergamot translator for dart:ffi (Mediahro, ADR-034).
// MPL-2.0, like bergamot-translator.
#include "mediahro_bergamot.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "translator/parser.h"
#include "translator/response_options.h"
#include "translator/service.h"

using marian::bergamot::BlockingService;
using marian::bergamot::ResponseOptions;
using marian::bergamot::TranslationModel;

struct mh_bergamot {
  std::unique_ptr<BlockingService> service;
};

struct mh_bergamot_model {
  std::shared_ptr<TranslationModel> model;
};

extern "C" {

mh_bergamot *mh_bergamot_new(int cache_size) {
  try {
    BlockingService::Config config;
    config.cacheSize = cache_size > 0 ? static_cast<size_t>(cache_size) : 0;
    auto *s = new mh_bergamot;
    s->service = std::make_unique<BlockingService>(config);
    return s;
  } catch (...) {
    return nullptr;
  }
}

void mh_bergamot_free(mh_bergamot *service) { delete service; }

mh_bergamot_model *mh_bergamot_load(mh_bergamot *service,
                                    const char *config_yaml, char *err,
                                    int err_len) {
  auto fail = [&](const char *message) -> mh_bergamot_model * {
    if (err != nullptr && err_len > 0) {
      std::snprintf(err, static_cast<size_t>(err_len), "%s", message);
    }
    return nullptr;
  };
  if (service == nullptr || config_yaml == nullptr) return fail("bad arguments");
  try {
    auto options = marian::bergamot::parseOptionsFromString(
        config_yaml, /*validate=*/false);
    auto *m = new mh_bergamot_model;
    m->model = std::make_shared<TranslationModel>(options);
    return m;
  } catch (const std::exception &e) {
    return fail(e.what());
  } catch (...) {
    return fail("unknown error");
  }
}

void mh_bergamot_model_free(mh_bergamot_model *model) { delete model; }

int mh_bergamot_translate(mh_bergamot *service, mh_bergamot_model *model,
                          const char *const *lines, int n, char **out) {
  if (service == nullptr || model == nullptr || lines == nullptr ||
      out == nullptr || n < 0) {
    return -1;
  }
  try {
    std::vector<std::string> sources;
    sources.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; i++) sources.emplace_back(lines[i] ? lines[i] : "");
    std::vector<ResponseOptions> options(static_cast<size_t>(n));
    auto responses = service->service->translateMultiple(
        model->model, std::move(sources), options);
    if (responses.size() != static_cast<size_t>(n)) return -1;
    std::vector<char *> texts;
    texts.reserve(responses.size());
    for (const auto &r : responses) {
      char *t = static_cast<char *>(std::malloc(r.target.text.size() + 1));
      if (t == nullptr) {
        for (char *done : texts) std::free(done);
        return -1;
      }
      std::memcpy(t, r.target.text.c_str(), r.target.text.size() + 1);
      texts.push_back(t);
    }
    for (int i = 0; i < n; i++) out[i] = texts[static_cast<size_t>(i)];
    return 0;
  } catch (...) {
    return -1;
  }
}

void mh_bergamot_free_text(char *text) { std::free(text); }

}  // extern "C"
