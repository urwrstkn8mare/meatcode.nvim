// Runtime support for neetcode.nvim's local C++ test harness.
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
#include <queue>
#include <sstream>
#include <string>
#include <vector>

namespace ncrt {

// ---------------------------------------------------------------- JSON value

struct JV {
  enum Type { NUL, BOOL, NUM, STR, ARR } type = NUL;
  bool b = false;
  double num = 0;
  std::string str;
  std::vector<JV> arr;
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

  if (s[i] == '[') {
    v.type = JV::ARR;
    i++;
    skipWs(s, i);
    if (i < s.size() && s[i] == ']') { i++; return v; }
    while (i < s.size()) {
      v.arr.push_back(parseValue(s, i));
      skipWs(s, i);
      if (i < s.size() && s[i] == ',') { i++; continue; }
      if (i < s.size() && s[i] == ']') { i++; break; }
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

using Args = std::vector<std::pair<std::string, JV> >;

// Split a `name=value` block into ordered (name, value) pairs.
inline Args parseArgs(const std::string &block) {
  Args out;
  std::istringstream lines(block);
  std::string line;
  while (std::getline(lines, line)) {
    size_t eq = line.find('=');
    if (eq == std::string::npos) continue;
    std::string name = line.substr(0, eq);
    std::string raw = line.substr(eq + 1);
    while (!name.empty() && isspace((unsigned char)name.front())) name.erase(name.begin());
    while (!name.empty() && isspace((unsigned char)name.back())) name.pop_back();
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

template <class T>
inline void conv(const JV &v, std::vector<T> &out) {
  out.clear();
  out.reserve(v.arr.size());
  for (const JV &e : v.arr) {
    T item;
    conv(e, item);
    out.push_back(item);
  }
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

// Order-insensitive form, used only to explain a near miss.
inline std::string canonical(const std::string &json) {
  JV v = parseJson(json);
  if (v.type != JV::ARR) return json;
  std::vector<std::string> parts;
  for (const JV &e : v.arr) {
    size_t i = 0;
    (void)i;
    if (e.type == JV::ARR) {
      std::vector<std::string> inner;
      for (const JV &x : e.arr) inner.push_back(x.type == JV::STR ? tj(x.str) : tj(x.num));
      std::sort(inner.begin(), inner.end());
      std::string s = "[";
      for (size_t k = 0; k < inner.size(); k++) { if (k) s += ","; s += inner[k]; }
      parts.push_back(s + "]");
    } else if (e.type == JV::STR) {
      parts.push_back(tj(e.str));
    } else {
      parts.push_back(tj(e.num));
    }
  }
  std::sort(parts.begin(), parts.end());
  std::string s = "[";
  for (size_t i = 0; i < parts.size(); i++) { if (i) s += ","; s += parts[i]; }
  return s + "]";
}

}  // namespace ncrt
