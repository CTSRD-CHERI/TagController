###########################
# Reads
###########################
# ALL: 0x00000000 - 0x0fff ffff (1024 root lines)
# Root   only: 0x0000 0000 -> 0x07ff ffff (512 root lines)
# Root & leaf: 0x0800 0000 -> 0x0fff ffff (512 root lines)
###########################
# Sets
###########################
# ALL: 0x1000 0000 - 0x1fff ffff (1024 root lines)
# New leaf:   0x1000 0000 -> 0x17ff ffff (512 root lines)
# Old leaf:   0x1800 0000 -> 0x1fff ffff (512 root lines)
###########################
# Clears
###########################
# ALL: 0x2000 0000 - 0x3fff ffff (2048 root lines)
# Root only:     0x2000 0000 -> 0x27ff ffff (512 root lines)
# Root & leaf:   0x2800 0000 -> 0x2fff ffff (512 root lines)
# Fold root hit  0x3000 0000 -> 0x37ff ffff (512 root lines)
# Fold root miss 0x3800 0000 -> 0x3fff ffff (512 root lines)
# Fold all miss  0x4000 0000 -> ?


class ReadAdder:
    def __init__(self, trace_generator):
        # Root only read
        trace_generator.add_read(0x00000000)
        # Leaf read
        trace_generator.add_write(0x08000000, 0x1217, 1, init=True)
        trace_generator.add_read(0x08000000)

        self.trace_generator = trace_generator
        self.read_r_hit = 0x00000000
        self.read_rl_hit = 0x08000000
        self.root_stride = 128 * 128 * 16 * 4
        self.leaf_stride = 128 * 16
        self.next_r_miss = self.read_r_hit + self.root_stride
        self.next_rl_l_miss = 1

    def read_root_only(self, miss=False):
        if miss:
            self.trace_generator.add_read(self.next_r_miss)
            self.next_r_miss += self.root_stride
        else:
            self.trace_generator.add_read(self.read_r_hit)

    def read_both(self, r_miss=False, l_miss=False):
        if r_miss:
            # if root not cached can assume leaf also not cached
            addr = self.next_r_miss
            self.trace_generator.add_write(addr, 0, 1, init=True)
            # Root & leaf miss
            self.trace_generator.add_read(addr)
            self.next_r_miss += self.root_stride
            self.next_rl_l_miss = 1
        elif l_miss:
            if self.next_rl_l_miss >= 128:
                print("READ PANIC: too many leaf misses without root miss")
                return
            addr = (self.next_r_miss - self.root_stride) + (
                self.next_rl_l_miss * self.leaf_stride
            )
            # Root hits, leaf miss
            self.trace_generator.add_write(addr, 0, 1, init=True)
            self.trace_generator.add_read(addr)
            self.next_rl_l_miss += 1
        else:
            # Both hit
            self.trace_generator.add_read(self.read_rl_hit)


class SetAdder:
    def __init__(self, trace_generator):
        # Set new leaf
        trace_generator.add_read(0x10000000)
        # Set normal
        trace_generator.add_write(0x18000000, 0x1217, 1, init=True)
        trace_generator.add_read(0x18000000)

        self.trace_generator = trace_generator
        self.set_r_hit = 0x10000000
        self.set_rl_hit = 0x18000000
        self.root_stride = 128 * 128 * 16 * 4
        self.leaf_stride = 128 * 16
        self.next_r_miss = self.set_r_hit + self.root_stride
        self.next_rl_l_miss = 1

    def new_set(self, r_miss=False, l_miss=False):
        if r_miss:
            # if root not cached can assume leaf also not cached
            addr = self.next_r_miss
            # Root & leaf miss
            self.trace_generator.add_write(addr, 0, 1)
            self.next_r_miss += self.root_stride
            self.next_rl_l_miss = 1
        elif l_miss:
            if self.next_rl_l_miss >= 128:
                print("SET PANIC: too many leaf misses without root miss")
                return
            addr = (self.next_r_miss - self.root_stride) + (
                self.next_rl_l_miss * self.leaf_stride
            )
            # Root hits, leaf miss
            self.trace_generator.add_write(addr, 0, 1)
            self.next_rl_l_miss += 1
        else:
            # Both hit
            self.trace_generator.add_write(self.set_rl_hit, 0, 1)


class ClearAdder:
    def __init__(self, trace_generator):
        # Clear only root
        trace_generator.add_read(0x20000000)
        # Clear root & leaf
        trace_generator.add_write(0x28000000, 0x1217, 1, init=True)
        trace_generator.add_read(0x28000000)

        self.root_stride = 128 * 128 * 16 * 4
        self.leaf_stride = 128 * 16

        for r in range(128):
            # Fold root & leaf hit
            addr = 0x30000000 + (r * self.leaf_stride)
            trace_generator.add_write(addr, 0x1217, 1, init=True)
            trace_generator.add_read(addr)
            # Fold root only hit
            addr = 0x33FFFFFF + (r * self.leaf_stride)
            trace_generator.add_write(addr, 0x1217, 1, init=True)
        trace_generator.add_read(0x33FFFFFF)

        self.trace_generator = trace_generator

        self.clear_r_hit = 0x20000000
        self.clear_rl_hit = 0x28000000 + 16  # don't cause fold

        self.next_clear_r_miss = self.clear_r_hit + self.root_stride
        self.next_clear_rl_l_miss = 1

        self.next_fold_r_hit = 0x33FFFFFF + self.leaf_stride
        self.next_fold_rl_hit = 0x30000000
        self.fold_r_hits_remaining = 127
        self.fold_rl_hits_remaining = 128

        self.next_fold_r_miss = 0x4000000

    def new_clear_root(self, miss=False):
        if miss:
            self.trace_generator.add_write(self.next_clear_r_miss, 0, 0)
            self.next_clear_r_miss += self.root_stride
        else:
            self.trace_generator.add_write(self.clear_r_hit, 0, 0)

    def new_clear_both(self, r_miss=False, l_miss=False):
        if r_miss:
            # if root not cached can assume leaf also not cached
            addr = self.next_clear_r_miss
            self.trace_generator.add_write(addr, 0, 1, init=True)
            # Root & leaf miss
            self.trace_generator.add_write(addr + 16, 0, 0)  # Don't cause fold
            self.next_clear_r_miss += self.root_stride
            self.next_clear_rl_l_miss = 1
        elif l_miss:
            if self.next_clear_rl_l_miss >= 128:
                print("CLEAR PANIC: too many leaf misses without root miss")
                return
            addr = (self.next_clear_r_miss - self.root_stride) + (
                self.next_clear_rl_l_miss * self.leaf_stride
            )
            # Root hits, leaf miss
            self.trace_generator.add_write(addr, 0, 1, init=True)
            self.trace_generator.add_write(addr + 16, 0, 0)  # Don't cause fold
            self.next_clear_rl_l_miss += 1
        else:
            # Both hit
            self.trace_generator.add_write(self.clear_rl_hit, 0, 0)

    def new_fold(self, r_miss=False, l_miss=False):
        if r_miss:
            addr = self.next_fold_r_miss
            self.trace_generator.add_write(addr, 0, 1, init=True)
            self.trace_generator.add_write(addr, 0, 0)
            self.next_fold_r_miss += self.root_stride
        elif l_miss:
            if self.fold_r_hits_remaining <= 0:
                print("FOLD PANIC Too many fold root only hits")
            addr = self.next_fold_r_hit
            # Root hits but leaf miss
            self.trace_generator.add_write(addr, 0, 0)
            self.next_fold_r_hit += self.leaf_stride
            self.fold_r_hits_remaining -= 1
        else:
            if self.fold_r_hits_remaining <= 0:
                print("FOLD PANIC Too many fold both hits")
            addr = self.next_fold_rl_hit
            # Root and leaf both hit
            self.trace_generator.add_write(addr, 0, 0)
            self.next_fold_rl_hit += self.leaf_stride
            self.fold_rl_hits_remaining -= 1
