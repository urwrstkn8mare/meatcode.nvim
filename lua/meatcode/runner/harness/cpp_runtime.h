// Runtime support for meatcode.nvim's local C++ test harness.
//
// NeetCode encodes test case inputs as newline-separated `name=value` blocks
// where each value is a JSON literal. C++ has no reflection, so the generated
// main.cpp declares typed locals and relies on the conv()/tj() overload sets
// below to marshal values in and serialise results back out.
#pragma once

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <optional>
#include <typeinfo>
#include <queue>
#include <sstream>
#include <string>
#include <vector>
#include <typeindex>
#include <stdexcept>
#include <initializer_list>
#include <cctype>
#include <set>
#include <type_traits>
#include <utility>
#include <new>
#include <cmath>
#include <limits>
#include <unistd.h>


namespace ncrt {

// ---------------------------------------------------------------- JSON value

struct JV {
  enum Type { NUL, BOOL, NUM, STR, ARR, OBJ } type = NUL;
  bool b = false;
  double num = 0;
  std::string str;
  std::vector<JV> arr;
  std::vector<std::pair<std::string, JV> > obj;
};

inline void skipWs(const std::string &s, size_t &i) {
  while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
}

inline JV parseValue(const std::string &s, size_t &i);

inline JV parseString(const std::string &s, size_t &i) {
  JV v; v.type = JV::STR;
  i++; // opening quote
  while (i < s.size() && s[i] != '"') {
    if (s[i] == '\\' && i + 1 < s.size()) {
      char c = s[++i];
      switch (c) {
        case 'n': v.str += '\n'; break;
        case 't': v.str += '\t'; break;
        case 'r': v.str += '\r'; break;
        case 'b': v.str += '\b'; break;
        case 'f': v.str += '\f'; break;
        case 'u': {
          // Only the BMP subset that fits in a byte shows up in test data.
          std::string hex = s.substr(i + 1, 4);
          i += 4;
          v.str += static_cast<char>(strtol(hex.c_str(), nullptr, 16));
          break;
        }
        default: v.str += c;
      }
      i++;
    } else {
      v.str += s[i++];
    }
  }
  i++; // closing quote
  return v;
}

inline JV parseValue(const std::string &s, size_t &i) {
  skipWs(s, i);
  JV v;
  if (i >= s.size()) return v;
  if (s[i] == '"') return parseString(s, i);

  if (s[i] == '{') {
    v.type = JV::OBJ;
    i++;
    skipWs(s, i);
    if (i < s.size() && s[i] == '}') { i++; return v; }
    while (i < s.size() && s[i] == '"') {
      JV key = parseString(s, i);
      skipWs(s, i);
      if (i >= s.size() || s[i++] != ':') break;
      v.obj.push_back(std::make_pair(key.str, parseValue(s, i)));
      skipWs(s, i);
      if (i < s.size() && s[i] == ',') { i++; skipWs(s, i); continue; }
      if (i < s.size() && s[i] == '}') i++;
      break;
    }
    return v;
  }
  if (s[i] == '[' || s[i] == '(') {
    const char close = s[i] == '(' ? ')' : ']';
    v.type = JV::ARR;
    i++;
    skipWs(s, i);
    if (i < s.size() && s[i] == close) { i++; return v; }
    while (i < s.size()) {
      v.arr.push_back(parseValue(s, i));
      skipWs(s, i);
      if (i < s.size() && s[i] == ',') { i++; continue; }
      if (i < s.size() && s[i] == close) { i++; break; }
      break;
    }
    return v;
  }

  if (!s.compare(i, 4, "true")) { v.type = JV::BOOL; v.b = true; i += 4; return v; }
  if (!s.compare(i, 5, "false")) { v.type = JV::BOOL; v.b = false; i += 5; return v; }
  if (!s.compare(i, 4, "null")) { v.type = JV::NUL; i += 4; return v; }

  size_t start = i;
  while (i < s.size() && (isdigit((unsigned char)s[i]) || s[i] == '-' || s[i] == '+' ||
                          s[i] == '.' || s[i] == 'e' || s[i] == 'E')) i++;
  std::string tok = s.substr(start, i - start);
  v.type = JV::NUM;

  // Bit-manipulation problems pass 32-bit values as zero-padded binary
  // strings, which atof would read as a huge decimal.
  bool allBinary = tok.size() == 32;
  for (size_t k = 0; allBinary && k < tok.size(); k++) {
    if (tok[k] != '0' && tok[k] != '1') allBinary = false;
  }
  if (allBinary) {
    v.num = (double)strtoull(tok.c_str(), nullptr, 2);
    return v;
  }
  if (tok.size() > 1 && tok[0] == '0' && tok.find('.') == std::string::npos) {
    v.num = (double)strtoll(tok.c_str(), nullptr, 10);
    return v;
  }
  v.num = atof(tok.c_str());
  return v;
}

inline JV parseJson(const std::string &s) {
  size_t i = 0;
  return parseValue(s, i);
}
inline const JV &field(const JV &v, const std::string &name, size_t index) {
  static const JV empty;
  if (v.type == JV::OBJ) {
    for (const auto &entry : v.obj) if (entry.first == name) return entry.second;
    throw std::runtime_error("record object is missing required field `" + name + "`");
  }
  return index < v.arr.size() ? v.arr[index] : empty;
}

struct ListNode;
struct TreeNode;
inline void conv(const JV &v, ListNode *&out);
inline void conv(const JV &v, TreeNode *&out);
inline JV to_value(ListNode *value);
inline JV to_value(TreeNode *value);
template <class T> inline void conv(const JV &, std::vector<T> &);
template <class T> inline void conv(const JV &, std::optional<T> &);
inline void conv(const JV &, std::vector<char> &);
template <class T> inline JV to_value(const std::vector<T> &);
template <class T> inline JV to_value(const std::optional<T> &);
template <class T> inline JV to_value(const std::map<std::string, T> &);
template <class T> inline JV to_value(const T &value);
template <class T> struct Codec;
template <class T> inline void conv(const JV &, std::map<std::string, T> &);
template <class T> inline T from_json(const JV &);
inline JV to_value(int);
inline JV to_value(long);
inline JV to_value(long long);
inline JV to_value(unsigned);
inline JV to_value(unsigned long);
inline JV to_value(unsigned long long);
inline JV to_value(double);
inline JV to_value(float);
inline JV to_value(bool);
inline JV to_value(char);
inline JV to_value(const std::string &);
template <class T>
inline typename std::enable_if<!std::is_same<T, ListNode>::value
  && !std::is_same<T, TreeNode>::value, JV>::type to_value(T *const &);
inline const JV &fieldOpt(const JV &v, const std::string &name, size_t index) {
  static const JV empty;
  if (v.type == JV::OBJ) {
    for (const auto &entry : v.obj) if (entry.first == name) return entry.second;
    return empty;
  }
  return index < v.arr.size() ? v.arr[index] : empty;
}
inline bool has_field(const JV &v, const char *name, size_t index) {
  if (v.type == JV::OBJ) {
    for (const auto &entry : v.obj) if (entry.first == name) return true;
    return false;
  }
  return index < v.arr.size();
}

// Named-object field validation: unknown keys and duplicates fail; optional
// fields may be omitted; the identity tags of reference-capable types are
// skipped here and handled by the pointer codecs.
inline void check_object(const JV &v, const char *type_name,
                         std::initializer_list<const char *> names,
                         std::initializer_list<const char *> optional_names) {
  if (v.type != JV::OBJ) return;
  for (const auto &entry : v.obj) {
    if (entry.first == "$id" || entry.first == "$ref") continue;
    bool known = false;
    for (const char *n : names) if (entry.first == n) { known = true; break; }
    if (!known) throw std::runtime_error(std::string("record ") + type_name + " has unknown field `" + entry.first + "`");
    size_t count = 0;
    for (const auto &other : v.obj) if (other.first == entry.first) count++;
    if (count > 1) throw std::runtime_error(std::string("record ") + type_name + " has duplicate field `" + entry.first + "`");
  }
  for (const char *n : names) {
    bool optional = false;
    for (const char *o : optional_names) if (std::string(n) == o) { optional = true; break; }
    if (optional) continue;
    bool present = false;
    for (const auto &entry : v.obj) if (entry.first == n) { present = true; break; }
    if (!present) throw std::runtime_error(std::string("missing required field ") + type_name + "." + n);
  }
}

// Identity tags must never appear where only a value record is expected.
inline void reject_identity_tags(const JV &v, const char *type_name) {
  if (v.type != JV::OBJ) return;
  for (const auto &entry : v.obj) {
    if (entry.first == "$id" || entry.first == "$ref")
      throw std::runtime_error(std::string("identity tags are unsupported on value record ") + type_name);
  }
}
template <class T>
inline void destroy_owned(void *ptr) {
  static_cast<T *>(ptr)->~T();
  ::operator delete(ptr, std::align_val_t(alignof(T)));
}

// ------------------------------------------------------- identity registry
//
// One registry per case: `$id` definitions and `$ref` lookups share it across
// all arguments and design operations of the case, then the drivers reset it
// so nothing leaks between cases, between the user and reference blocks, or
// across parallel workers (separate processes).
struct Identity {
  struct Entry {
    void *ptr = nullptr;
    const JV *definition = nullptr;
    std::type_index type = std::type_index(typeid(void));
    bool constructing = false;
    bool filled = false;
  };
  std::map<std::string, Entry> by_id;
  std::map<const void *, long long> encoded;
  std::vector<std::pair<void *, void (*)(void *)> > owned;
  long long next_id = 0;
  bool identity_used = false;
  bool graph_mode = false;
  void reset() {
    for (auto it = owned.rbegin(); it != owned.rend(); ++it) it->second(it->first);
    owned.clear(); by_id.clear(); encoded.clear(); next_id = 0;
    identity_used = false; graph_mode = false;
  }
  void verify() {
    for (const auto &kv : by_id)
      if (kv.second.ptr && !kv.second.filled)
        throw std::runtime_error("unresolved identity reference to `" + kv.first + "`");
  }
};

inline Identity &identity() { static Identity ctx; return ctx; }
inline void reset_identity() { identity().reset(); }
inline std::string identity_key(const JV &v, const char *what) {
  if (v.type == JV::NUM && std::isfinite(v.num) && std::trunc(v.num) == v.num
      && v.num >= -9223372036854775808.0 && v.num < 9223372036854775808.0)
    return "i:" + std::to_string(static_cast<long long>(v.num));
  if (v.type == JV::STR && !v.str.empty()) return "s:" + v.str;
  throw std::runtime_error(std::string("identity ") + what + " must be a nonempty string or integer");
}

struct IdentityTags {
  const JV *id = nullptr;
  const JV *ref = nullptr;
};
inline IdentityTags identity_tags(const JV &v) {
  IdentityTags tags;
  for (const auto &entry : v.obj) {
    if (entry.first == "$id") {
      if (tags.id) throw std::runtime_error("identity object has duplicate `$id` tag");
      tags.id = &entry.second;
    } else if (entry.first == "$ref") {
      if (tags.ref) throw std::runtime_error("identity object has duplicate `$ref` tag");
      tags.ref = &entry.second;
    }
  }
  if (tags.id && tags.ref)
    throw std::runtime_error("identity object cannot carry both `$id` and `$ref`");
  if (tags.ref && v.obj.size() != 1)
    throw std::runtime_error("a `$ref` object must contain exactly one `$ref` field");
  return tags;
}

// Index borrowed JSON definitions across the entire case before decoding any
// argument. No graph subtree is copied; forward references eagerly construct
// their indexed target before control enters a user method.
inline void preindex(const JV &v) {
  if (v.type == JV::OBJ) {
    auto tags = identity_tags(v);
    if (tags.id) {
      auto key = identity_key(*tags.id, "id");
      auto &entry = identity().by_id[key];
      if (entry.definition && entry.definition != &v)
        throw std::runtime_error("duplicate identity id `" + key + "`");
      entry.definition = &v;
    }
    if (tags.ref) identity_key(*tags.ref, "reference");
    for (const auto &entry : v.obj) preindex(entry.second);
  } else if (v.type == JV::ARR) {
    for (const JV &child : v.arr) preindex(child);
  }
}
template <class Pairs>
inline void preindex_args(const Pairs &args) {
  for (const auto &arg : args) preindex(arg.second);
}

template <class T>
inline T *identity_object(const std::string &key, const JV *definition) {
  auto &entry = identity().by_id[key];
  if (definition) {
    if (entry.definition && entry.definition != definition)
      throw std::runtime_error("duplicate identity id `" + key + "`");
    entry.definition = definition;
  }
  if (!entry.definition)
    throw std::runtime_error("unresolved identity reference to `" + key + "`");
  if (entry.type != std::type_index(typeid(void))
      && entry.type != std::type_index(typeid(T)))
    throw std::runtime_error(std::string("identity reference has the wrong type: id `") + key
      + "` is not a " + Codec<T>::name());
  if (!entry.ptr) {
    entry.ptr = ::operator new(sizeof(T), std::align_val_t(alignof(T)));
    entry.type = std::type_index(typeid(T));
  }
  T *ptr = static_cast<T *>(entry.ptr);
  if (!entry.filled && !entry.constructing) {
    entry.constructing = true;
    try { Codec<T>::construct(*entry.definition, entry.ptr); }
    catch (...) {
      ::operator delete(entry.ptr, std::align_val_t(alignof(T)));
      entry.ptr = nullptr;
      entry.constructing = false;
      throw;
    }
    entry.filled = true;
    entry.constructing = false;
    identity().owned.emplace_back(entry.ptr, &destroy_owned<T>);
  }
  return ptr;
}
template <class T> struct IsVector : std::false_type {};
template <class T, class A> struct IsVector<std::vector<T, A> > : std::true_type { using value_type = T; };
template <class T> struct IsOptional : std::false_type {};
template <class T> struct IsOptional<std::optional<T> > : std::true_type { using value_type = T; };
template <class T> struct IsStringMap : std::false_type {};
template <class T, class C, class A>
struct IsStringMap<std::map<std::string, T, C, A> > : std::true_type { using value_type = T; };
template <class T>
inline void preindex_typed(const JV &v) {
  using U = typename std::remove_cv<T>::type;
  if constexpr (std::is_pointer<U>::value) {
    using V = typename std::remove_cv<typename std::remove_pointer<U>::type>::type;
    if constexpr (!std::is_same<V, ListNode>::value && !std::is_same<V, TreeNode>::value) {
      // Null has no nested identity. Indexing it would re-enter this record's
      // pointer fields forever (a null `next` is not another node).
      if (v.type == JV::NUL) return;
      if (v.type == JV::OBJ) {
        const auto tags = identity_tags(v);
        if (tags.id || tags.ref) {
          const auto key = identity_key(tags.id ? *tags.id : *tags.ref,
            tags.id ? "id" : "reference");
          auto &entry = identity().by_id[key];
          if (entry.type != std::type_index(typeid(void))
              && entry.type != std::type_index(typeid(V)))
            throw std::runtime_error("identity reference has the wrong type: id `" + key + "`");
          entry.type = std::type_index(typeid(V));
          if (tags.id) Codec<V>::preindex(v);
          return;
        }
      }
      if (v.type == JV::ARR || v.type == JV::OBJ) Codec<V>::preindex(v);
    }
  } else if constexpr (std::is_arithmetic<U>::value || std::is_same<U, std::string>::value) {
    return;
  } else if constexpr (std::is_same<U, std::vector<char>>::value) {
    return;
  } else if constexpr (IsVector<U>::value) {
    if (v.type == JV::ARR)
      for (const JV &child : v.arr) preindex_typed<typename IsVector<U>::value_type>(child);
  } else if constexpr (IsOptional<U>::value) {
    if (v.type != JV::NUL) preindex_typed<typename IsOptional<U>::value_type>(v);
  } else if constexpr (IsStringMap<U>::value) {
    if (v.type == JV::OBJ)
      for (const auto &entry : v.obj) preindex_typed<typename IsStringMap<U>::value_type>(entry.second);
  } else {
    Codec<U>::preindex(v);
  }
}

template <class T>
inline void conv_ref(const JV &v, T *&out) {
  if (v.type == JV::NUL) { out = nullptr; return; }
  if (v.type != JV::OBJ && v.type != JV::ARR)
    throw std::runtime_error("reference-capable record input must be an array or object");
  auto tags = identity_tags(v);
  if (tags.id || tags.ref) {
    identity().identity_used = true;
    out = identity_object<T>(identity_key(tags.id ? *tags.id : *tags.ref,
      tags.id ? "id" : "reference"), tags.id ? &v : nullptr);
    return;
  }
  void *storage = ::operator new(sizeof(T), std::align_val_t(alignof(T)));
  try { Codec<T>::construct(v, storage); }
  catch (...) { ::operator delete(storage, std::align_val_t(alignof(T))); throw; }
  identity().owned.emplace_back(storage, &destroy_owned<T>);
  out = static_cast<T *>(storage);
}

struct ListNode;
struct TreeNode;
struct WalkState {
  std::vector<const void *> encountered;
  std::set<const void *> expanded;
};
template <class T, class = void> struct HasCodecWalk : std::false_type {};
template <class T>
struct HasCodecWalk<T, std::void_t<decltype(Codec<T>::walk(
  static_cast<const T *>(nullptr), std::declval<WalkState &>()))> > : std::true_type {};

inline void walk_references(ListNode *, WalkState &) {}
inline void walk_references(TreeNode *, WalkState &) {}
template <class T>
inline void walk_references(T *ptr, WalkState &state) {
  // `const Token*` and `Token*` share one codec. Deduction keeps the const
  // on T, and there is no Codec<const Token> specialization.
  using U = std::remove_cv_t<T>;
  if (!ptr) return;
  state.encountered.push_back(ptr);
  if (!state.expanded.insert(ptr).second) return;
  Codec<U>::walk(ptr, state);
}
template <class T>
inline typename std::enable_if<HasCodecWalk<T>::value>::type
walk_references(const T &value, WalkState &state) {
  Codec<T>::walk(&value, state);
}
template <class T>
inline typename std::enable_if<!HasCodecWalk<T>::value>::type
walk_references(const T &, WalkState &) {}
template <class T> inline void walk_references(const std::vector<T> &, WalkState &);
template <class T> inline void walk_references(const std::optional<T> &, WalkState &);
template <class T> inline void walk_references(const std::map<std::string, T> &, WalkState &);
template <class T>
inline void walk_references(const std::vector<T> &values, WalkState &state) {
  for (const T &value : values) walk_references(value, state);
}
template <class T>
inline void walk_references(const std::optional<T> &value, WalkState &state) {
  if (value) walk_references(*value, state);
}
template <class T>
inline void walk_references(const std::map<std::string, T> &values, WalkState &state) {
  for (const auto &entry : values) walk_references(entry.second, state);
}
template <class T>
inline bool identity_sharing(const T &value) {
  WalkState state;
  walk_references(value, state);
  std::map<const void *, int> counts;
  for (const void *ptr : state.encountered) counts[ptr]++;
  for (const auto &entry : counts) {
    if (entry.second > 1 || identity().encoded.count(entry.first)) return true;
  }
  return false;
}
template <class T>
inline void conv(const JV &v, T *&out) { conv_ref(v, out); }


// Positional serialization of a nested custom pointer field (used when the
// case runs in positional mode). The pointed-to record serializes as a
// positional array; null serializes as JSON null.
template <class T>
inline JV to_value_pos(T *const &ptr) {
  if (!ptr) return JV();
  return Codec<std::remove_cv_t<T>>::encode(*ptr);
}
inline std::string render(const JV &v);

// Graph-mode encoding of a nested custom pointer field: canonical integer
// `$id` values in first-encounter order, repeats as `{"$ref":n}`.
template <class T>
inline JV to_value_ref(T *const &ptr) { return Codec<std::remove_cv_t<T>>::encode_ref(ptr); }
template <class T>
inline typename std::enable_if<!std::is_same<T, ListNode>::value
  && !std::is_same<T, TreeNode>::value, JV>::type
to_value(T *const &ptr) {
  return identity().graph_mode ? to_value_ref(ptr) : to_value_pos(ptr);
}



// Encode a pointer of record type T. The whole return value runs in ONE
// global mode: identity (id/ref objects) when the case carried explicit
// input ids or the graph has sharing/cycles, else plain positional arrays.
template <class T>
inline std::string tj_ref(const T *ptr) {
  if (!ptr) return "null";
  bool graph = identity().identity_used || identity_sharing(ptr);
  identity().graph_mode = graph;
  JV v = graph ? Codec<T>::encode_ref(ptr) : Codec<T>::encode(*ptr);
  identity().graph_mode = false;
  return render(v);
}


using Args = std::vector<std::pair<std::string, JV> >;

// Split an input block into ordered (name, value) pairs. NeetCode labels every
// value (`nums=[1,2]`); LeetCode and LintCode hand out bare values, one per
// line, in signature order, which bind by position and carry an empty name.
inline Args parseArgs(const std::string &block) {
  Args out;
  std::istringstream lines(block);
  std::string line;
  while (std::getline(lines, line)) {
    size_t eq = line.find('=');
    std::string name, raw;
    if (eq == std::string::npos) {
      raw = line;
    } else {
      name = line.substr(0, eq);
      raw = line.substr(eq + 1);
      while (!name.empty() && isspace((unsigned char)name.front())) name.erase(name.begin());
      while (!name.empty() && isspace((unsigned char)name.back())) name.pop_back();
      // Only an identifier is a label; anything else was part of the value.
      bool ident = !name.empty() && (isalpha((unsigned char)name[0]) || name[0] == '_');
      for (size_t i = 0; ident && i < name.size(); i++) {
        if (!isalnum((unsigned char)name[i]) && name[i] != '_') ident = false;
      }
      if (!ident) {
        name.clear();
        raw = line;
      }
    }
    bool blank = true;
    for (size_t i = 0; i < raw.size(); i++) {
      if (!isspace((unsigned char)raw[i])) { blank = false; break; }
    }
    if (blank) continue;
    out.push_back(std::make_pair(name, parseJson(raw)));
  }
  return out;
}

// Prefer a match on parameter name, but fall back to position: reference
// solutions sometimes name a parameter differently from the test-case input.
//! Everything after the leading method name of an operation.
inline JV tail(const JV &op) {
  JV out;
  out.type = JV::ARR;
  for (size_t i = 1; i < op.arr.size(); i++) out.arr.push_back(op.arr[i]);
  return out;
}

//! Bounds-checked element access; a missing argument reads as null.
inline const JV &argAt(const JV &args, size_t i) {
  static const JV nul;
  return i < args.arr.size() ? args.arr[i] : nul;
}

inline const JV &pick(const Args &args, size_t index, const std::string &name) {
  static const JV empty;
  for (size_t i = 0; i < args.size(); i++) {
    if (args[i].first == name) return args[i].second;
  }
  if (index < args.size()) return args[index].second;
  return empty;
}

// ------------------------------------------------------------- linked / tree

struct ListNode {
  int val;
  ListNode *next;
  ListNode() : val(0), next(nullptr) {}
  ListNode(int x) : val(x), next(nullptr) {}
  ListNode(int x, ListNode *n) : val(x), next(n) {}
};

struct TreeNode {
  int val;
  TreeNode *left;
  TreeNode *right;
  TreeNode() : val(0), left(nullptr), right(nullptr) {}
  TreeNode(int x) : val(x), left(nullptr), right(nullptr) {}
  TreeNode(int x, TreeNode *l, TreeNode *r) : val(x), left(l), right(r) {}
};


inline ListNode *buildList(const JV &v) {
  ListNode *head = nullptr;
  for (size_t i = v.arr.size(); i-- > 0;) head = new ListNode((int)v.arr[i].num, head);
  return head;
}

inline TreeNode *buildTree(const JV &v) {
  if (v.arr.empty() || v.arr[0].type == JV::NUL) return nullptr;
  TreeNode *root = new TreeNode((int)v.arr[0].num);
  std::queue<TreeNode *> q;
  q.push(root);
  size_t i = 1;
  while (!q.empty() && i < v.arr.size()) {
    TreeNode *node = q.front(); q.pop();
    if (i < v.arr.size()) {
      const JV &l = v.arr[i++];
      if (l.type != JV::NUL) { node->left = new TreeNode((int)l.num); q.push(node->left); }
    }
    if (i < v.arr.size()) {
      const JV &r = v.arr[i++];
      if (r.type != JV::NUL) { node->right = new TreeNode((int)r.num); q.push(node->right); }
    }
  }
  return root;
}

// Locate an existing node by value. Some problems (lowestCommonAncestor's `p`
// and `q`) pass a scalar that identifies a node inside another argument's tree.
inline TreeNode *findByValue(TreeNode *root, int target) {
  if (!root) return nullptr;
  std::queue<TreeNode *> q;
  q.push(root);
  while (!q.empty()) {
    TreeNode *n = q.front(); q.pop();
    if (!n) continue;
    if (n->val == target) return n;
    q.push(n->left);
    q.push(n->right);
  }
  return nullptr;
}

inline ListNode *findByValue(ListNode *head, int target) {
  for (ListNode *n = head; n; n = n->next) {
    if (n->val == target) return n;
  }
  return nullptr;
}

// ------------------------------------------------------------ JSON -> native

//! Some test cases quote their numbers ("1" rather than 1), so a value that
//! arrives as a string still has to read back as the declared type.
inline double asNum(const JV &v) {
  if (v.type == JV::STR) {
    try { return std::stod(v.str); } catch (...) { return 0; }
  }
  if (v.type == JV::BOOL) return v.b ? 1 : 0;
  return v.num;
}

inline std::string asStr(const JV &v) {
  if (v.type == JV::STR) return v.str;
  if (v.type == JV::BOOL) return v.b ? "true" : "false";
  if (v.type == JV::NUL) return "";
  std::ostringstream ss;
  if (v.num == (long long)v.num) ss << (long long)v.num; else ss << v.num;
  return ss.str();
}

inline void conv(const JV &v, int &out) { out = (int)asNum(v); }
inline void conv(const JV &v, long &out) { out = (long)asNum(v); }
inline void conv(const JV &v, long long &out) { out = (long long)asNum(v); }
inline void conv(const JV &v, unsigned &out) { out = (unsigned)asNum(v); }
inline void conv(const JV &v, unsigned long &out) { out = (unsigned long)asNum(v); }
inline void conv(const JV &v, unsigned long long &out) { out = (unsigned long long)asNum(v); }
inline void conv(const JV &v, double &out) { out = asNum(v); }
inline void conv(const JV &v, float &out) { out = (float)asNum(v); }
inline void conv(const JV &v, bool &out) { out = v.type == JV::BOOL ? v.b : asNum(v) != 0; }
inline void conv(const JV &v, char &out) { out = v.str.empty() ? '\0' : v.str[0]; }
inline void conv(const JV &v, std::string &out) { out = asStr(v); }
inline void conv(const JV &v, ListNode *&out) { out = buildList(v); }
inline void conv(const JV &v, TreeNode *&out) { out = buildTree(v); }

// Factories construct values directly, including non-default-constructible
// records and immutable fields. Container elements never need T{} or assignment.
template <class T, class = void> struct JsonFactory {
  static T decode(const JV &v) { return Codec<T>::decode(v); }
};
template <class T>
struct JsonFactory<T, std::enable_if_t<std::is_arithmetic<T>::value
  || std::is_same<T, std::string>::value>> {
  static T decode(const JV &v) { T out{}; conv(v, out); return out; }
};
template <class T> struct JsonFactory<T *> {
  static T *decode(const JV &v) {
    T *out = nullptr;
    conv(v, out);
    return out;
  }
};
template <class T> struct JsonFactory<std::vector<T>> {
  static std::vector<T> decode(const JV &v) {
    if (v.type != JV::ARR) throw std::runtime_error("vector input must be an array");
    std::vector<T> out;
    out.reserve(v.arr.size());
    for (const JV &child : v.arr) out.emplace_back(from_json<T>(child));
    return out;
  }
};
template <> struct JsonFactory<std::vector<char>> {
  static std::vector<char> decode(const JV &v) {
    std::vector<char> out;
    conv(v, out);
    return out;
  }
};
template <class T> struct JsonFactory<std::optional<T>> {
  static std::optional<T> decode(const JV &v) {
    if (v.type == JV::NUL) return std::nullopt;
    return std::optional<T>(std::in_place, from_json<T>(v));
  }
};
template <class T> struct JsonFactory<std::map<std::string, T>> {
  static std::map<std::string, T> decode(const JV &v) {
    if (v.type != JV::OBJ) throw std::runtime_error("map input must be an object");
    std::map<std::string, T> out;
    for (const auto &entry : v.obj)
      if (!out.emplace(entry.first, from_json<T>(entry.second)).second)
        throw std::runtime_error("map input has duplicate key `" + entry.first + "`");
    return out;
  }
};
template <class T> inline T from_json(const JV &v) { return JsonFactory<T>::decode(v); }
template <class T> inline void conv(const JV &v, T &out) { out = from_json<T>(v); }
template <class T>
inline void conv(const JV &v, std::vector<T> &out) { out = from_json<std::vector<T>>(v); }
template <class T>
inline void conv(const JV &v, std::optional<T> &out) {
  out.reset();
  if (v.type != JV::NUL) out.emplace(from_json<T>(v));
}
template <class T>
inline void conv(const JV &v, std::map<std::string, T> &out) {
  out = from_json<std::map<std::string, T>>(v);
}


// A vector<char> is encoded as a JSON string when it stands for a word.
inline void conv(const JV &v, std::vector<char> &out) {
  out.clear();
  if (v.type == JV::STR) {
    for (char c : v.str) out.push_back(c);
    return;
  }
  for (const JV &e : v.arr) out.push_back(e.str.empty() ? (char)e.num : e.str[0]);
}

// ------------------------------------------------------------ native -> JSON

inline std::string tj(const std::string &v);
inline std::string render(const JV &v);
template <class T> inline std::string tj(const T &v);

inline std::string tj(int v) { return std::to_string(v); }
inline std::string tj(long v) { return std::to_string(v); }
inline std::string tj(long long v) { return std::to_string(v); }
inline std::string tj(unsigned v) { return std::to_string(v); }
inline std::string tj(unsigned long v) { return std::to_string(v); }
inline std::string tj(unsigned long long v) { return std::to_string(v); }
inline std::string tj(bool v) { return v ? "true" : "false"; }

inline std::string tj(double v) {
  if (v == (long long)v && std::abs(v) < 1e15) return std::to_string((long long)v);
  char buf[64];
  snprintf(buf, sizeof(buf), "%.5f", v);
  std::string s(buf);
  while (!s.empty() && s.back() == '0') s.pop_back();
  if (!s.empty() && s.back() == '.') s.pop_back();
  return s;
}
inline std::string tj(float v) { return tj((double)v); }

inline std::string tj(const std::string &v) {
  std::string out = "\"";
  for (char c : v) {
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if (c == '\n') out += "\\n";
    else if (c == '\t') out += "\\t";
    else out += c;
  }
  return out + "\"";
}
inline std::string tj(char v) { return tj(std::string(1, v)); }

template <class T> inline std::string tj(const std::vector<T> &v);

inline std::string tj(ListNode *n) {
  std::string out = "[";
  int guard = 0;
  for (; n && guard < 100000; n = n->next, guard++) {
    if (guard) out += ",";
    out += std::to_string(n->val);
  }
  return out + "]";
}

inline std::string tj(TreeNode *root) {
  std::vector<std::string> out;
  if (root) {
    std::queue<TreeNode *> q;
    q.push(root);
    while (!q.empty()) {
      TreeNode *n = q.front(); q.pop();
      if (!n) { out.push_back("null"); continue; }
      out.push_back(std::to_string(n->val));
      q.push(n->left);
      q.push(n->right);
    }
    while (!out.empty() && out.back() == "null") out.pop_back();
  }
  std::string s = "[";
  for (size_t i = 0; i < out.size(); i++) { if (i) s += ","; s += out[i]; }
  return s + "]";
}

template <class T>
inline std::string tj(const std::vector<T> &v) {
  std::string out = "[";
  for (size_t i = 0; i < v.size(); i++) {
    if (i) out += ",";
    out += tj(v[i]);
  }
  return out + "]";
}
inline std::string render(const JV &v);
inline JV to_value(int v) { JV x; x.type=JV::NUM; x.num=v; return x; }
inline JV to_value(long v) { JV x; x.type=JV::NUM; x.num=v; return x; }
inline JV to_value(long long v) { JV x; x.type=JV::NUM; x.num=(double)v; return x; }
inline JV to_value(unsigned v) { JV x; x.type=JV::NUM; x.num=v; return x; }
inline JV to_value(unsigned long v) { JV x; x.type=JV::NUM; x.num=v; return x; }
inline JV to_value(unsigned long long v) { JV x; x.type=JV::NUM; x.num=(double)v; return x; }
inline JV to_value(double v) { JV x; x.type=JV::NUM; x.num=v; return x; }
inline JV to_value(float v) { return to_value((double)v); }
inline JV to_value(bool v) { JV x; x.type=JV::BOOL; x.b=v; return x; }
inline JV to_value(const std::string &v) { JV x; x.type=JV::STR; x.str=v; return x; }
inline JV to_value(char v) { JV x; x.type=JV::STR; x.str.push_back(v); return x; }
template <class T> inline JV to_value(const std::vector<T> &v) {
  JV x; x.type=JV::ARR; x.arr.reserve(v.size());
  for (const T &e : v) x.arr.push_back(to_value(e));
  return x;
}

// Linked/tree nodes keep the existing positional encodings ([1,2,3] and
// level order), so a ListNode*/TreeNode* field inside a record serializes
// exactly like a top-level argument does.
inline JV to_value(ListNode *n) {
  JV x; x.type = JV::ARR;
  int guard = 0;
  for (; n && guard < 100000; n = n->next, guard++) x.arr.push_back(to_value(n->val));
  return x;
}
inline JV to_value(TreeNode *root) {
  JV x; x.type = JV::ARR;
  if (root) {
    std::queue<TreeNode *> q;
    q.push(root);
    while (!q.empty()) {
      TreeNode *n = q.front(); q.pop();
      if (!n) { x.arr.push_back(JV()); continue; }
      x.arr.push_back(to_value(n->val));
      q.push(n->left);
      q.push(n->right);
    }
    while (!x.arr.empty() && x.arr.back().type == JV::NUL) x.arr.pop_back();
  }
  return x;
}

template <class T>
inline JV to_value(const std::optional<T> &v) { return v ? to_value(*v) : JV(); }

template <class T>
inline JV to_value(const std::map<std::string, T> &m) {
  JV x; x.type = JV::OBJ;
  for (const auto &entry : m) x.obj.push_back(std::make_pair(entry.first, to_value(entry.second)));
  return x;
}
template <class T> inline JV to_value(const T &v) { return Codec<T>::encode(v); }
template <class T> inline std::string tj(const T &v) { return render(to_value(v)); }


// Re-serialise parsed JSON the way `tj` writes it, so an answer copied out of a
// problem statement ("[0, 1]") compares equal to a solution's output ("[0,1]").
inline std::string render(const JV &v) {
  switch (v.type) {
    case JV::NUL: return "null";
    case JV::BOOL: return v.b ? "true" : "false";
    case JV::NUM: return tj(v.num);
    case JV::STR: return tj(v.str);
    case JV::ARR: {
      std::string out = "[";
      for (size_t i = 0; i < v.arr.size(); i++) {
        if (i) out += ",";
        out += render(v.arr[i]);
      }
      return out + "]";
    }
    case JV::OBJ: {
      std::string out = "{";
      for (size_t i = 0; i < v.obj.size(); i++) {
        if (i) out += ",";
        out += tj(v.obj[i].first) + ":" + render(v.obj[i].second);
      }
      return out + "}";
    }
  }
  return "null";
}

template <class T>
inline std::string tj_graph(const T &value) {
  const bool graph = identity().identity_used || identity_sharing(value);
  identity().graph_mode = graph;
  JV encoded = to_value(value);
  identity().graph_mode = false;
  return render(encoded);
}

inline JV sortedObjects(JV value) {
  for (JV &child : value.arr) child = sortedObjects(child);
  for (auto &entry : value.obj) entry.second = sortedObjects(entry.second);
  std::sort(value.obj.begin(), value.obj.end(),
    [](const std::pair<std::string, JV> &a, const std::pair<std::string, JV> &b) {
      return a.first < b.first;
    });
  return value;
}

// Order-insensitive form, used only to explain a near miss.
inline std::string canonical_value(const JV &v) {
  if (v.type == JV::ARR) {
    std::vector<std::string> parts;
    parts.reserve(v.arr.size());
    for (const JV &child : v.arr) parts.push_back(canonical_value(child));
    std::sort(parts.begin(), parts.end());
    std::string out = "[";
    for (size_t i = 0; i < parts.size(); i++) {
      if (i) out += ",";
      out += parts[i];
    }
    return out + "]";
  }
  if (v.type == JV::OBJ) {
    std::vector<std::pair<std::string, std::string> > fields;
    fields.reserve(v.obj.size());
    for (const auto &entry : v.obj)
      fields.push_back(std::make_pair(entry.first, canonical_value(entry.second)));
    std::sort(fields.begin(), fields.end(),
      [](const std::pair<std::string, std::string> &a, const std::pair<std::string, std::string> &b) {
        return a.first < b.first;
      });
    std::string out = "{";
    for (size_t i = 0; i < fields.size(); i++) {
      if (i) out += ",";
      out += tj(fields[i].first) + ":" + fields[i].second;
    }
    return out + "}";
  }
  return render(v);
}

inline std::string canonical(const std::string &json) {
  return canonical_value(parseJson(json));
}

// Grade `actual` against a list of acceptable rendered answers, implementing
// the same contract as the Python harness's `judge`: an empty `answers`
// yields `no_oracle` with no expected value; an exact match is a `pass`;
// failing that, an order-insensitive (`canonical`) match is a
// `pass_unordered`; otherwise `fail`, reported against the first answer.
// Returns the status string and writes the answer to display into `expected`.
inline std::string judge(const std::string &actual,
                          const std::vector<std::string> &answers,
                          std::string &expected) {
  if (answers.empty()) return "no_oracle";
  expected = answers[0];
  const std::string actualExact = render(sortedObjects(parseJson(actual)));
  for (const std::string &ans : answers) {
    if (actualExact == render(sortedObjects(parseJson(ans)))) { expected = ans; return "pass"; }
  }
  std::string actualCanon = canonical(actual);
  for (const std::string &ans : answers) {
    if (actualCanon == canonical(ans)) { expected = ans; return "pass_unordered"; }
  }
  return "fail";
}

// ------------------------------------------------------------------ crashes

// The solution's stdout while it runs. A sanitizer report ends the process
// before the harness can print its results, so the report's death callback
// writes the tail of this buffer to stderr, after a
// `CRASH STDOUT <bytes shown> <bytes total>` line, for the results panel.
inline std::stringbuf *capturing = nullptr;

inline void dumpCapture() {
  if (!capturing) return;
#if __cplusplus >= 202002L
  auto out = capturing->view();  // no allocation while the process is dying
  const char *data = out.data();
  size_t total = out.size();
#else
  std::string out = capturing->str();
  const char *data = out.data();
  size_t total = out.size();
#endif
  const size_t limit = 64 * 1024;
  size_t shown = total < limit ? total : limit;
  char head[64];
  int n = std::snprintf(head, sizeof head, "\nCRASH STDOUT %zu %zu\n", shown, total);
  if (n > 0) (void)!write(2, head, (size_t)n);
  (void)!write(2, data + (total - shown), shown);
}

}  // namespace ncrt

// Defaults for AddressSanitizer and UndefinedBehaviorSanitizer, which the
// default runner.cpp.cmd enables; harmless when they are off. Solutions and
// this harness never free their nodes, so leak checking stays off. A report
// exits with status 1 instead of aborting, and aborts and traps (a failed
// libc++ hardening check, assert()) get a stack trace too. Undefined behaviour
// stops the run at the first report, as it does on LeetCode.
extern "C" __attribute__((used, visibility("default"))) const char *__asan_default_options() {
  return "detect_leaks=0:abort_on_error=0:handle_abort=1:handle_sigill=1:handle_sigtrap=1:"
         "dump_registers=0:print_legend=0";
}
extern "C" __attribute__((used, visibility("default"))) const char *__ubsan_default_options() {
  return "halt_on_error=1:print_stacktrace=1";
}

#if defined(__SANITIZE_ADDRESS__)
#define NCRT_SANITIZED 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer) || __has_feature(undefined_behavior_sanitizer)
#define NCRT_SANITIZED 1
#endif
#endif

#ifdef NCRT_SANITIZED
extern "C" void __sanitizer_set_death_callback(void (*callback)(void));
#endif

namespace ncrt {

inline void installCrashHooks() {
#ifdef NCRT_SANITIZED
  __sanitizer_set_death_callback(dumpCapture);
#endif
}

}  // namespace ncrt
