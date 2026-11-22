defmodule OzMcp.Utils.TokenBucketTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.TokenBucket

  describe "new/2 and take/3" do
    test "a new bucket gives rate messages at the same now, then drops" do
      bucket = TokenBucket.new(3, 0)

      assert {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      assert {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      assert {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      assert {:drop, _bucket} = TokenBucket.take(bucket, 3, 0)
    end

    test "an empty bucket needs one full token to accept a message" do
      bucket = TokenBucket.new(3, 0)

      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      {:drop, bucket} = TokenBucket.take(bucket, 3, 0)

      assert {:drop, _bucket} = TokenBucket.take(bucket, 3, 333)
      assert {:ok, _bucket} = TokenBucket.take(bucket, 3, 334)
    end

    test "a long pause refills the bucket to the burst only" do
      bucket = TokenBucket.new(3, 0)

      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)

      pause = 60 * 60 * 1_000

      assert {:ok, bucket} = TokenBucket.take(bucket, 3, pause)
      assert {:ok, bucket} = TokenBucket.take(bucket, 3, pause)
      assert {:ok, bucket} = TokenBucket.take(bucket, 3, pause)
      assert {:drop, _bucket} = TokenBucket.take(bucket, 3, pause)
    end

    test "a now smaller than at adds no token" do
      bucket = TokenBucket.new(3, 1_000)

      {:ok, bucket} = TokenBucket.take(bucket, 3, 1_000)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 1_000)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 1_000)
      {:drop, bucket} = TokenBucket.take(bucket, 3, 1_000)

      assert {:drop, _bucket} = TokenBucket.take(bucket, 3, 0)
    end

    test "a drop does not remove tokens" do
      bucket = TokenBucket.new(3, 0)

      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)
      {:ok, bucket} = TokenBucket.take(bucket, 3, 0)

      assert {:drop, dropped} = TokenBucket.take(bucket, 3, 0)
      assert dropped.level == bucket.level

      assert {:ok, _bucket} = TokenBucket.take(dropped, 3, 334)
    end
  end
end
