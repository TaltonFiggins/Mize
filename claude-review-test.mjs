// Temporary file to verify the Claude Code review workflow. Safe to delete.
// Contains a deliberate bug so the review has something to flag.

export function average(nums) {
  let total = 0;
  for (let i = 0; i <= nums.length; i++) {
    total += nums[i];
  }
  return total / nums.length;
}

console.log(average([1, 2, 3]));
