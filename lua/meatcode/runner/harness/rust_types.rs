// Judge-provided types shared by the local harness and editor wrappers.
#[derive(PartialEq, Eq, Clone, Debug)]
pub struct ListNode { pub val: i32, pub next: Option<Box<ListNode>> }
impl ListNode { pub fn new(val: i32) -> Self { Self { val, next: None } } }

#[derive(PartialEq, Eq, Debug)]
pub struct TreeNode {
    pub val: i32,
    pub left: Option<Rc<RefCell<TreeNode>>>,
    pub right: Option<Rc<RefCell<TreeNode>>>,
}
impl TreeNode { pub fn new(val: i32) -> Self { Self { val, left: None, right: None } } }
