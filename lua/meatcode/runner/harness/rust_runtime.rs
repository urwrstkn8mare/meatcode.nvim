use std::{any::{Any,TypeId}, cell::RefCell, collections::{BTreeMap,HashMap,HashSet,VecDeque}, env, fs, io::Write, os::fd::AsRawFd, rc::Rc, time::Instant};
use std::fmt::Write as FormatWrite;

#[derive(Clone, Debug)]
enum Json { Null, Bool(bool), Number(String), String(String), Array(Vec<Json>), Object(BTreeMap<String,Json>), Reference(String) }

struct Parser<'a> { bytes: &'a [u8], pos: usize }
impl<'a> Parser<'a> {
    fn whitespace(&mut self) {
        while matches!(self.bytes.get(self.pos), Some(b' ' | b'\n' | b'\r' | b'\t')) { self.pos += 1; }
    }
    fn take(&mut self, byte: u8) -> bool {
        self.whitespace();
        if self.bytes.get(self.pos) == Some(&byte) { self.pos += 1; true } else { false }
    }
    fn word(&mut self, word: &[u8]) -> Result<(), String> {
        if self.bytes.get(self.pos..self.pos + word.len()) != Some(word) { return Err("invalid JSON token".into()); }
        self.pos += word.len(); Ok(())
    }
    fn hex(&mut self) -> Result<u16, String> {
        let bytes = self.bytes.get(self.pos..self.pos + 4).ok_or("incomplete Unicode escape")?;
        let text = std::str::from_utf8(bytes).map_err(|_| "invalid Unicode escape")?;
        let value = u16::from_str_radix(text, 16).map_err(|_| "invalid Unicode escape")?;
        self.pos += 4; Ok(value)
    }
    fn string(&mut self) -> Result<String, String> {
        if !self.take(b'"') { return Err("expected a JSON string".into()); }
        let mut output = String::new();
        let mut start = self.pos;
        loop {
            let byte = *self.bytes.get(self.pos).ok_or("unterminated JSON string")?;
            if byte == b'"' || byte == b'\\' {
                output.push_str(std::str::from_utf8(&self.bytes[start..self.pos]).map_err(|_| "invalid UTF-8")?);
                self.pos += 1;
                if byte == b'"' { return Ok(output); }
                let escaped = *self.bytes.get(self.pos).ok_or("incomplete JSON escape")?;
                self.pos += 1;
                match escaped {
                    b'"' => output.push('"'), b'\\' => output.push('\\'), b'/' => output.push('/'),
                    b'b' => output.push('\u{8}'), b'f' => output.push('\u{c}'),
                    b'n' => output.push('\n'), b'r' => output.push('\r'), b't' => output.push('\t'),
                    b'u' => {
                        let high = self.hex()?;
                        let scalar = if (0xd800..=0xdbff).contains(&high) {
                            self.word(b"\\u")?;
                            let low = self.hex()?;
                            if !(0xdc00..=0xdfff).contains(&low) { return Err("invalid Unicode surrogate pair".into()); }
                            0x10000 + (((high as u32 - 0xd800) << 10) | (low as u32 - 0xdc00))
                        } else { high as u32 };
                        output.push(char::from_u32(scalar).ok_or("invalid Unicode scalar")?);
                    }
                    _ => return Err("invalid JSON escape".into()),
                }
                start = self.pos;
            } else {
                if byte < 0x20 { return Err("unescaped control character".into()); }
                self.pos += 1;
            }
        }
    }
    fn number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.bytes.get(self.pos) == Some(&b'-') { self.pos += 1; }
        match self.bytes.get(self.pos) {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => { while matches!(self.bytes.get(self.pos), Some(b'0'..=b'9')) { self.pos += 1; } }
            _ => return Err("invalid JSON number".into()),
        }
        if self.bytes.get(self.pos) == Some(&b'.') {
            self.pos += 1; let digits = self.pos;
            while matches!(self.bytes.get(self.pos), Some(b'0'..=b'9')) { self.pos += 1; }
            if self.pos == digits { return Err("invalid JSON fraction".into()); }
        }
        if matches!(self.bytes.get(self.pos), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.bytes.get(self.pos), Some(b'+' | b'-')) { self.pos += 1; }
            let digits = self.pos;
            while matches!(self.bytes.get(self.pos), Some(b'0'..=b'9')) { self.pos += 1; }
            if self.pos == digits { return Err("invalid JSON exponent".into()); }
        }
        Ok(Json::Number(std::str::from_utf8(&self.bytes[start..self.pos]).unwrap().to_owned()))
    }
    fn value(&mut self) -> Result<Json, String> {
        self.whitespace();
        match self.bytes.get(self.pos) {
            Some(b'n') => { self.word(b"null")?; Ok(Json::Null) }
            Some(b't') => { self.word(b"true")?; Ok(Json::Bool(true)) }
            Some(b'f') => { self.word(b"false")?; Ok(Json::Bool(false)) }
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b'[') => {
                self.pos += 1; let mut values = Vec::new();
                if self.take(b']') { return Ok(Json::Array(values)); }
                loop {
                    values.push(self.value()?);
                    if self.take(b']') { break; }
                    if !self.take(b',') { return Err("expected an array comma".into()); }
                }
                Ok(Json::Array(values))
            }
            Some(b'{') => {
                self.pos += 1; let mut values=BTreeMap::new();
                if self.take(b'}') { return Ok(Json::Object(values)); }
                loop {
                    let key=self.string()?;
                    if !self.take(b':') { return Err("expected an object colon".into()); }
                    if values.insert(key,self.value()?).is_some() { return Err("duplicate JSON object key".into()); }
                    if self.take(b'}') { break; }
                    if !self.take(b',') { return Err("expected an object comma".into()); }
                }
                Ok(Json::Object(values))
            }
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err("unsupported or invalid JSON value".into()),
        }
    }
}
fn parse(text: &str) -> Result<Json, String> {
    let mut parser = Parser { bytes: text.as_bytes(), pos: 0 };
    let value = parser.value()?; parser.whitespace();
    if parser.pos != parser.bytes.len() { return Err("trailing JSON input".into()); }
    Ok(value)
}
fn quote_into(output: &mut String, text: &str) {
    output.push('"');
    for ch in text.chars() {
        match ch {
            '"' => output.push_str("\\\""), '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"), '\r' => output.push_str("\\r"), '\t' => output.push_str("\\t"),
            ch if ch < '\u{20}' => { let _ = write!(output, "\\u{:04x}", ch as u32); }
            ch => output.push(ch),
        }
    }
    output.push('"');
}
fn array(value: Json) -> Result<Vec<Json>, String> {
    match value { Json::Array(values) => Ok(values), _ => Err("expected an array".into()) }
}
fn arguments(value: Json) -> Result<Vec<Json>, String> {
    let mut values=array(value)?.into_iter().map(|value| match value {
        Json::String(raw) => parse(&raw), _ => Err("expected raw JSON argument text".into()),
    }).collect::<Result<Vec<_>,_>>()?;
    initialize_graph(&mut values)?;Ok(values)
}
trait FromJson: Sized { fn from_json(value: Json) -> Result<Self, String>; }
trait ToJson {
    const HAS_REFERENCES: bool = false;
    fn to_json(&self, output: &mut String);
    fn shared_reference(&self, _seen: &mut HashSet<(TypeId,usize)>) -> bool { false }
}
trait GraphRecord: FromJson + ToJson + 'static {
    fn graph_empty() -> Self;
    fn graph_populate(&mut self, fields:BTreeMap<String,Json>)->Result<(),String>;
    fn graph_fields(&self, output:&mut String);
}
enum Emit { Positional, Ref(usize), Id(usize) }
struct DecodeContext {
    definitions:BTreeMap<String,BTreeMap<String,Json>>, objects:HashMap<String,Box<dyn Any>>,
    output:HashMap<(TypeId,usize),(usize,Box<dyn Any>)>, graph:bool, next_output:usize,
}
impl DecodeContext { fn new()->Self { Self { definitions:BTreeMap::new(),objects:HashMap::new(),output:HashMap::new(),graph:false,next_output:1 } } }
thread_local! {
    static CODEC_CONTEXT: RefCell<DecodeContext> = RefCell::new(DecodeContext::new());
}
fn identity_id(value:&Json)->Result<String,String> {
    match value {
        Json::String(s) if !s.is_empty()=>Ok(format!("s:{}",s)),
        Json::Number(s) if !s.contains('.')&&!s.contains('e')&&!s.contains('E')=>s.parse::<i128>().map(|n|format!("n:{}",n)).map_err(|_|"invalid identity integer".into()),
        _=>Err("identity must be a nonempty string or integer".into()),
    }
}
fn index_graph(value:&mut Json,context:&mut DecodeContext)->Result<(),String> {
    let current=std::mem::replace(value,Json::Null);
    match current {
        Json::Array(mut values)=>{
            for child in &mut values { index_graph(child,context)?; }
            *value=Json::Array(values);
        }
        Json::Object(mut values)=>{
            if values.contains_key("$id") && values.contains_key("$ref") { return Err("object cannot contain both $id and $ref".into()); }
            if let Some(id)=values.get("$id") {
                let key=identity_id(id)?;
                for (name,child) in values.iter_mut() { if name!="$id" { index_graph(child,context)?; } }
                values.remove("$id");
                if context.definitions.insert(key.clone(),values).is_some() { return Err("duplicate identity id".into()); }
                context.graph=true;
                *value=Json::Reference(key);
            } else if values.contains_key("$ref") {
                if values.len()!=1 { return Err("a reference object must contain only $ref".into()); }
                let key=identity_id(values.get("$ref").unwrap())?;
                context.graph=true;
                *value=Json::Reference(key);
            } else {
                for child in values.values_mut() { index_graph(child,context)?; }
                *value=Json::Object(values);
            }
        }
        value_json=>*value=value_json,
    }
    Ok(())
}
fn initialize_graph(values:&mut [Json])->Result<(),String> {
    CODEC_CONTEXT.with(|slot| { let mut context=slot.borrow_mut();*context=DecodeContext::new();
        for value in values { index_graph(value,&mut context)?; }Ok(()) })
}
fn graph_resolve<T:GraphRecord>(id:String)->Result<Rc<RefCell<T>>,String> {
    let (target,definition)=CODEC_CONTEXT.with(|slot| -> Result<(Rc<RefCell<T>>,Option<BTreeMap<String,Json>>),String> {
        let mut context=slot.borrow_mut();
        if let Some(value)=context.objects.get(&id) {
            let target=value.downcast_ref::<Rc<RefCell<T>>>().ok_or("identity reference has the wrong type")?.clone();
            return Ok((target,None));
        }
        let definition=context.definitions.remove(&id).ok_or("unresolved identity reference")?;
        let target=Rc::new(RefCell::new(T::graph_empty()));
        context.objects.insert(id,Box::new(target.clone()));
        Ok((target,Some(definition)))
    })?;
    if let Some(fields)=definition { target.borrow_mut().graph_populate(fields)?; }
    Ok(target)
}
impl<T:GraphRecord> FromJson for Rc<RefCell<T>> {
    fn from_json(value:Json)->Result<Self,String> {
        match value {
            Json::Reference(id)=>graph_resolve::<T>(id),
            Json::Object(fields) if fields.contains_key("$id") && fields.contains_key("$ref")=>Err("object cannot contain both $id and $ref".into()),
            Json::Object(fields) if fields.contains_key("$ref")=>{
                if fields.len()!=1 { return Err("a reference object must contain only $ref".into()); }
                graph_resolve::<T>(identity_id(fields.get("$ref").unwrap())?)
            }
            Json::Object(fields) if fields.contains_key("$id")=>graph_resolve::<T>(identity_id(fields.get("$id").unwrap())?),
            value=>T::from_json(value).map(|value|Rc::new(RefCell::new(value))),
        }
    }
}
impl<T:GraphRecord> ToJson for Rc<RefCell<T>> {
    const HAS_REFERENCES: bool = true;
    fn shared_reference(&self, seen:&mut HashSet<(TypeId,usize)>) -> bool {
        let key=(TypeId::of::<T>(),Rc::as_ptr(self) as usize);
        !seen.insert(key) || self.borrow().shared_reference(seen)
    }
    fn to_json(&self,output:&mut String) {
        let address=Rc::as_ptr(self) as usize;
        let emit=CODEC_CONTEXT.with(|slot| {
            let mut context=slot.borrow_mut();
            let key=(TypeId::of::<T>(),address);
            if !context.graph { return Emit::Positional; }
            if let Some((id,_))=context.output.get(&key) { return Emit::Ref(*id); }
            let id=context.next_output;context.next_output+=1;
            context.output.insert(key,(id,Box::new(self.clone())));
            Emit::Id(id)
        });
        match emit {
            Emit::Positional=>self.borrow().to_json(output),
            Emit::Ref(id)=>{output.push_str("{\"$ref\":");id.to_json(output);output.push('}');}
            Emit::Id(id)=>{output.push_str("{\"$id\":");id.to_json(output);self.borrow().graph_fields(output);output.push('}');}
        }
    }
}
macro_rules! numbers {
    ($($ty:ty),*) => { $(
        impl FromJson for $ty {
            fn from_json(value: Json) -> Result<Self, String> {
                match value { Json::Number(text) => text.parse().map_err(|_| format!("invalid {} value", stringify!($ty))), _ => Err("expected a number".into()) }
            }
        }
        impl ToJson for $ty { fn to_json(&self, output: &mut String) { let _ = write!(output, "{}", self); } }
    )* };
}
numbers!(i8,i16,i32,i64,isize,u8,u16,u32,u64,usize,f32,f64);
impl FromJson for bool { fn from_json(value: Json) -> Result<Self,String> { match value { Json::Bool(value) => Ok(value), _ => Err("expected a boolean".into()) } } }
impl ToJson for bool { fn to_json(&self, output:&mut String) { output.push_str(if *self { "true" } else { "false" }); } }
impl FromJson for String { fn from_json(value:Json)->Result<Self,String> { match value { Json::String(value)=>Ok(value), _=>Err("expected a string".into()) } } }
impl ToJson for String { fn to_json(&self,output:&mut String) { quote_into(output,self); } }
impl FromJson for char {
    fn from_json(value:Json)->Result<Self,String> {
        let text=String::from_json(value)?; let mut chars=text.chars();
        let ch=chars.next().ok_or("expected a character")?;
        if chars.next().is_some() { return Err("expected exactly one character".into()); } Ok(ch)
    }
}
impl ToJson for char { fn to_json(&self,output:&mut String) { let mut bytes=[0;4];quote_into(output,self.encode_utf8(&mut bytes)); } }
impl<T:FromJson> FromJson for Vec<T> { fn from_json(value:Json)->Result<Self,String> { array(value)?.into_iter().map(T::from_json).collect() } }
impl<T:ToJson> ToJson for Vec<T> {
    const HAS_REFERENCES: bool = T::HAS_REFERENCES;
    fn shared_reference(&self, seen:&mut HashSet<(TypeId,usize)>) -> bool {
        T::HAS_REFERENCES && self.iter().any(|value|value.shared_reference(seen))
    }
    fn to_json(&self,output:&mut String) {
        output.push('[');for (i,value) in self.iter().enumerate() { if i>0 { output.push(','); } value.to_json(output); }output.push(']');
    }
}
fn encoded<T:ToJson>(value:&T)->String {
    if T::HAS_REFERENCES && !CODEC_CONTEXT.with(|slot|slot.borrow().graph)
        && value.shared_reference(&mut HashSet::new()) {
        CODEC_CONTEXT.with(|slot|slot.borrow_mut().graph=true);
    }
    let mut output=String::new();
    value.to_json(&mut output);
    output
}
impl<T:FromJson> FromJson for Box<T> {
    fn from_json(value:Json)->Result<Self,String> { T::from_json(value).map(Box::new) }
}
impl<T:ToJson> ToJson for Box<T> {
    const HAS_REFERENCES: bool = T::HAS_REFERENCES;
    fn to_json(&self,output:&mut String) { (**self).to_json(output); }
    fn shared_reference(&self,seen:&mut HashSet<(TypeId,usize)>)->bool { (**self).shared_reference(seen) }
}
impl<T:FromJson> FromJson for BTreeMap<String,T> {
    fn from_json(value:Json)->Result<Self,String> {
        match value { Json::Object(values)=>values.into_iter().map(|(key,value)|T::from_json(value).map(|value|(key,value))).collect(),
            _=>Err("expected an object map".into()) }
    }
}
impl<T:ToJson> ToJson for BTreeMap<String,T> {
    const HAS_REFERENCES: bool = T::HAS_REFERENCES;
    fn shared_reference(&self,seen:&mut HashSet<(TypeId,usize)>)->bool {
        T::HAS_REFERENCES && self.values().any(|value|value.shared_reference(seen))
    }
    fn to_json(&self,output:&mut String) {
        output.push('{');for (i,(key,value)) in self.iter().enumerate() {
            if i>0 { output.push(','); }quote_into(output,key);output.push(':');value.to_json(output);
        }output.push('}');
    }
}

impl FromJson for Option<Box<ListNode>> {
    fn from_json(value:Json)->Result<Self,String> {
        if matches!(value,Json::Null) { return Ok(None); }
        let values=array(value)?;let mut head=None;
        for value in values.into_iter().rev() { head=Some(Box::new(ListNode { val:i32::from_json(value)?,next:head })); } Ok(head)
    }
}
impl ToJson for Option<Box<ListNode>> {
    fn to_json(&self,output:&mut String) {
        output.push('[');let mut node=self.as_ref();let mut first=true;
        while let Some(current)=node { if !first { output.push(','); }first=false;current.val.to_json(output);node=current.next.as_ref(); }output.push(']');
    }
}
impl FromJson for Option<Rc<RefCell<TreeNode>>> {
    fn from_json(value:Json)->Result<Self,String> {
        if matches!(value,Json::Null) { return Ok(None); }
        let mut values=array(value)?.into_iter();
        let first=match values.next() { None|Some(Json::Null)=>return Ok(None),Some(value)=>value };
        let root=Rc::new(RefCell::new(TreeNode::new(i32::from_json(first)?)));
        let mut queue=VecDeque::new();queue.push_back(root.clone());
        while let Some(value)=values.next() {
            let parent=queue.pop_front().ok_or("tree contains unreachable nodes")?;
            if !matches!(value,Json::Null) { let node=Rc::new(RefCell::new(TreeNode::new(i32::from_json(value)?)));parent.borrow_mut().left=Some(node.clone());queue.push_back(node); }
            if let Some(value)=values.next() {
                if !matches!(value,Json::Null) { let node=Rc::new(RefCell::new(TreeNode::new(i32::from_json(value)?)));parent.borrow_mut().right=Some(node.clone());queue.push_back(node); }
            }
        }
        Ok(Some(root))
    }
}
impl ToJson for Option<Rc<RefCell<TreeNode>>> {
    fn to_json(&self,output:&mut String) {
        output.push('[');let mut queue=VecDeque::new();queue.push_back(self.clone());let mut first=true;let mut pending_nulls=0;
        while let Some(node)=queue.pop_front() {
            if let Some(node)=node {
                for _ in 0..pending_nulls { if !first { output.push(','); }output.push_str("null");first=false; }pending_nulls=0;
                if !first { output.push(','); }first=false;let node=node.borrow();node.val.to_json(output);
                queue.push_back(node.left.clone());queue.push_back(node.right.clone());
            } else { pending_nulls+=1; }
        }
        output.push(']');
    }
}
fn tree_argument(value:Json,root:&Option<Rc<RefCell<TreeNode>>>)->Result<Option<Rc<RefCell<TreeNode>>>,String> {
    if matches!(value,Json::Array(_)|Json::Null) { return Option::<Rc<RefCell<TreeNode>>>::from_json(value); }
    let target=i32::from_json(value)?;
    let mut queue=VecDeque::new();if let Some(root)=root { queue.push_back(root.clone()); }
    while let Some(node)=queue.pop_front() {
        let borrowed=node.borrow();if borrowed.val==target { drop(borrowed);return Ok(Some(node)); }
        if let Some(left)=&borrowed.left { queue.push_back(left.clone()); }
        if let Some(right)=&borrowed.right { queue.push_back(right.clone()); }
    }
    Err("tree node value does not exist in the root".into())
}

extern "C" { fn dup(fd:i32)->i32; fn dup2(old:i32,new:i32)->i32; fn close(fd:i32)->i32; fn fflush(stream:*mut std::ffi::c_void)->i32; }
struct StdoutCapture { saved:i32, file:fs::File, path:std::path::PathBuf }
impl Drop for StdoutCapture {
    fn drop(&mut self) {
        let _=std::io::stdout().flush();unsafe { fflush(std::ptr::null_mut());dup2(self.saved,1);close(self.saved); }
        let _=fs::remove_file(&self.path);
    }
}
fn capture<F:FnOnce()->Result<String,String>>(dir:&str,index:usize,oracle:bool,body:F)->(Result<String,String>,String) {
    let path=std::path::Path::new(dir).join(format!("stdout-{}-{}-{}",std::process::id(),index,oracle));
    let file=match fs::OpenOptions::new().create_new(true).write(true).open(&path) { Ok(file)=>file,Err(error)=>return (Err(format!("could not capture stdout: {}",error)),String::new()) };
    let _=std::io::stdout().flush();unsafe { fflush(std::ptr::null_mut()); }
    let saved=unsafe { dup(1) };
    if saved<0 { let _=fs::remove_file(&path);return (Err("could not capture stdout".into()),String::new()); }
    let guard=StdoutCapture { saved,file,path };
    if unsafe { dup2(guard.file.as_raw_fd(),1) }<0 { return (Err("could not redirect stdout".into()),String::new()); }
    let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)).unwrap_or_else(|panic| {
        let message=panic.downcast_ref::<String>().map(|s|s.as_str()).or_else(||panic.downcast_ref::<&str>().copied()).unwrap_or("solution panicked");Err(message.to_owned())
    });
    let _=std::io::stdout().flush();unsafe { fflush(std::ptr::null_mut()); }
    let logs=fs::read_to_string(&guard.path).unwrap_or_default();drop(guard);(result,logs)
}
fn read_array(dir:&str,name:&str)->Result<Vec<Json>,String> { array(parse(&fs::read_to_string(std::path::Path::new(dir).join(name)).map_err(|error|error.to_string())?)?) }
