class CourierPolicy {
  const CourierPolicy({
    this.capacityBytes = 1024 * 1024 * 1024,
    this.perDepositorBytes = 256 * 1024 * 1024,
    this.maxAssemblies = 4,
    this.maxRequests = 16,
    this.maxJobs = 1024,
    this.maxJobsPerDepositor = 128,
  });
  static const retentionMilliseconds = 24 * 60 * 60 * 1000;
  static const metadataBytes = 64 * 1024,
      packageOverhead = 8192,
      receiptBytes = 8192;
  final int capacityBytes,
      perDepositorBytes,
      maxAssemblies,
      maxRequests,
      maxJobs,
      maxJobsPerDepositor;
  static int packageCost(int cipherBytes) =>
      ((cipherBytes + 2) ~/ 3) * 4 + packageOverhead;
  void validate() {
    if (capacityBytes < metadataBytes ||
        capacityBytes > 1024 * 1024 * 1024 * 1024 ||
        perDepositorBytes < metadataBytes ||
        perDepositorBytes > capacityBytes ||
        maxAssemblies < 1 ||
        maxAssemblies > 4 ||
        maxRequests < 1 ||
        maxRequests > 16 ||
        maxJobs < 1 ||
        maxJobs > 1024 ||
        maxJobsPerDepositor < 1 ||
        maxJobsPerDepositor > maxJobs) {
      throw const FormatException('Invalid Courier policy');
    }
  }

  Map<String, Object> toJson() => {
    'capacityBytes': capacityBytes,
    'perDepositorBytes': perDepositorBytes,
    'maxAssemblies': maxAssemblies,
    'maxRequests': maxRequests,
    'maxJobs': maxJobs,
    'maxJobsPerDepositor': maxJobsPerDepositor,
  };
  factory CourierPolicy.fromJson(Map<String, dynamic> v) {
    final p = CourierPolicy(
      capacityBytes: v['capacityBytes'] as int,
      perDepositorBytes: v['perDepositorBytes'] as int,
      maxAssemblies: v['maxAssemblies'] as int,
      maxRequests: v['maxRequests'] as int,
      maxJobs: v['maxJobs'] as int,
      maxJobsPerDepositor: v['maxJobsPerDepositor'] as int,
    );
    p.validate();
    return p;
  }
}
