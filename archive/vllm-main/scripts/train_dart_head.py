#!/usr/bin/env python3
"""
DART Head Training Script
=========================

Train a DART draft head for speculative decoding on NVIDIA T4.

Usage:
    python train_dart_head.py --model meta-llama/Llama-3.1-8B-Instruct \
                              --dataset lmsys/lmsys-chat-1m \
                              --epochs 1 \
                              --output dart_head_llama8b.pt

Requirements:
    pip install torch transformers datasets accelerate bitsandbytes
"""

import argparse
import json
import os
import struct
import time
from pathlib import Path
from typing import Dict, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader
from transformers import AutoModelForCausalLM, AutoTokenizer
from datasets import load_dataset


# =============================================================================
# DART Head Model
# =============================================================================

class DARTHead(nn.Module):
    """
    DART draft head for parallel token prediction.
    
    Attaches to hidden states from layer N-4 of target model
    and predicts K future tokens in a single forward pass.
    """
    
    def __init__(
        self,
        hidden_size: int = 4096,
        head_hidden_size: int = 512,
        vocab_size: int = 128256,
        num_draft_positions: int = 4,
        num_heads: int = 8,
    ):
        super().__init__()
        
        self.hidden_size = hidden_size
        self.head_hidden_size = head_hidden_size
        self.vocab_size = vocab_size
        self.K = num_draft_positions
        self.num_heads = num_heads
        
        # Input projection
        self.input_proj = nn.Linear(hidden_size, head_hidden_size)
        
        # Learnable mask tokens for K draft positions
        self.mask_tokens = nn.Parameter(
            torch.randn(num_draft_positions, head_hidden_size) * 0.02
        )
        
        # Single transformer layer
        self.pre_norm = nn.LayerNorm(head_hidden_size)
        self.attention = nn.MultiheadAttention(
            head_hidden_size, 
            num_heads=num_heads, 
            batch_first=True,
            dropout=0.0,
        )
        
        # FFN
        self.post_norm = nn.LayerNorm(head_hidden_size)
        self.ffn = nn.Sequential(
            nn.Linear(head_hidden_size, head_hidden_size * 2),
            nn.GELU(),
            nn.Linear(head_hidden_size * 2, head_hidden_size),
        )
        
        # LM head
        self.lm_head = nn.Linear(head_hidden_size, vocab_size, bias=False)
    
    def forward(
        self, 
        hidden_states: torch.Tensor,  # [B, seq_len, hidden_size]
    ) -> torch.Tensor:
        """
        Forward pass.
        
        Args:
            hidden_states: Hidden states from target model layer N-4
        
        Returns:
            logits: [B, K, vocab_size] logits for K draft positions
        """
        B, seq_len, _ = hidden_states.shape
        
        # Project to head dimension
        x = self.input_proj(hidden_states)  # [B, seq_len, head_hidden]
        
        # Append K learnable mask tokens
        masks = self.mask_tokens.unsqueeze(0).expand(B, -1, -1)  # [B, K, head_hidden]
        x = torch.cat([x, masks], dim=1)  # [B, seq_len + K, head_hidden]
        
        # Build attention mask
        total_len = seq_len + self.K
        attn_mask = self._build_attention_mask(seq_len, self.K, x.device)
        
        # Self-attention
        x_norm = self.pre_norm(x)
        attn_out, _ = self.attention(
            x_norm, x_norm, x_norm, 
            attn_mask=attn_mask,
            need_weights=False,
        )
        x = x + attn_out
        
        # Extract draft positions
        draft_x = x[:, seq_len:, :]  # [B, K, head_hidden]
        
        # FFN
        draft_x = self.post_norm(draft_x)
        draft_x = draft_x + self.ffn(draft_x)
        
        # LM head
        logits = self.lm_head(draft_x)  # [B, K, vocab_size]
        
        return logits
    
    def _build_attention_mask(
        self, 
        prefix_len: int, 
        K: int, 
        device: torch.device,
    ) -> torch.Tensor:
        """
        Build attention mask for draft positions.
        
        - Prefix tokens can attend to each other (no causal)
        - Draft position i can attend to prefix + draft positions 0..i (causal)
        """
        total_len = prefix_len + K
        
        # Start with all blocked
        mask = torch.ones(total_len, total_len, dtype=torch.bool, device=device)
        
        # Prefix can attend to entire prefix
        mask[:prefix_len, :prefix_len] = False
        
        # Draft positions: can see prefix + causal over draft
        for i in range(K):
            draft_idx = prefix_len + i
            mask[draft_idx, :prefix_len] = False  # Can see prefix
            mask[draft_idx, prefix_len:draft_idx + 1] = False  # Causal in draft
        
        return mask


# =============================================================================
# Dataset Processing
# =============================================================================

def prepare_dataset(
    tokenizer,
    dataset_name: str = "lmsys/lmsys-chat-1m",
    max_samples: int = 50000,
    max_length: int = 1024,
    K: int = 4,
):
    """Prepare training dataset."""
    
    print(f"Loading dataset: {dataset_name}")
    
    if dataset_name == "lmsys/lmsys-chat-1m":
        dataset = load_dataset(dataset_name, split="train", streaming=True)
        
        def extract_text(example):
            # Extract conversation text
            try:
                conv = example.get("conversation", [])
                if conv:
                    return {"text": conv[0].get("content", "")}
            except:
                pass
            return {"text": ""}
        
        dataset = dataset.map(extract_text)
    
    elif dataset_name == "HuggingFaceH4/ultrachat_200k":
        dataset = load_dataset(dataset_name, split="train_sft")
        
        def extract_text(example):
            messages = example.get("messages", [])
            if messages:
                return {"text": " ".join(m.get("content", "") for m in messages)}
            return {"text": ""}
        
        dataset = dataset.map(extract_text)
    
    else:
        # Generic text dataset
        dataset = load_dataset(dataset_name, split="train")
    
    def tokenize_function(examples):
        return tokenizer(
            examples["text"],
            truncation=True,
            max_length=max_length,
            padding="max_length",
            return_tensors="pt",
        )
    
    # Process samples
    processed = []
    count = 0
    
    for example in dataset:
        if count >= max_samples:
            break
        
        text = example.get("text", "")
        if len(text) < 100:  # Skip short texts
            continue
        
        tokens = tokenizer(
            text,
            truncation=True,
            max_length=max_length,
            padding=False,
            return_tensors="pt",
        )
        
        if tokens["input_ids"].shape[1] >= K + 10:  # Need at least K + 10 tokens
            processed.append({
                "input_ids": tokens["input_ids"].squeeze(0),
                "attention_mask": tokens["attention_mask"].squeeze(0),
            })
            count += 1
            
            if count % 1000 == 0:
                print(f"  Processed {count}/{max_samples} samples")
    
    print(f"Prepared {len(processed)} training samples")
    return processed


def collate_fn(batch):
    """Collate function for DataLoader."""
    input_ids = torch.stack([item["input_ids"] for item in batch])
    attention_mask = torch.stack([item["attention_mask"] for item in batch])
    return {"input_ids": input_ids, "attention_mask": attention_mask}


# =============================================================================
# Training Loop
# =============================================================================

def train(
    model_name: str,
    output_path: str,
    dataset_name: str = "lmsys/lmsys-chat-1m",
    epochs: int = 1,
    batch_size: int = 4,
    learning_rate: float = 5e-4,
    max_samples: int = 50000,
    K: int = 4,
    head_hidden: int = 512,
    layer_offset: int = 4,
    use_distillation: bool = True,
    distillation_temp: float = 2.0,
    distillation_alpha: float = 0.5,
    checkpoint_every: int = 1000,
):
    """
    Train DART head.
    
    Args:
        model_name: HuggingFace model name
        output_path: Path to save trained weights
        dataset_name: Dataset to train on
        epochs: Number of training epochs
        batch_size: Training batch size (4 for T4)
        learning_rate: Learning rate
        max_samples: Maximum training samples
        K: Number of draft positions
        head_hidden: DART head hidden dimension
        layer_offset: Extract hidden states from layer N - offset
        use_distillation: Use knowledge distillation
        distillation_temp: Distillation temperature
        distillation_alpha: Weight for distillation loss
        checkpoint_every: Save checkpoint every N steps
    """
    
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Using device: {device}")
    
    # Load tokenizer
    print(f"Loading tokenizer: {model_name}")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    
    # Load target model (INT8 for VRAM)
    print(f"Loading target model: {model_name}")
    target_model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype=torch.float16,
        device_map="auto",
        load_in_8bit=True,
    )
    target_model.eval()
    
    # Get model config
    config = target_model.config
    hidden_size = config.hidden_size
    vocab_size = config.vocab_size
    num_layers = config.num_hidden_layers
    
    print(f"  Hidden size: {hidden_size}")
    print(f"  Vocab size: {vocab_size}")
    print(f"  Layers: {num_layers}")
    
    # Hook to capture hidden states
    captured_hidden = {}
    hook_layer_idx = num_layers - layer_offset
    
    def hook_fn(module, inp, out):
        # out is tuple (hidden_states, ...)
        if isinstance(out, tuple):
            captured_hidden["hs"] = out[0].detach()
        else:
            captured_hidden["hs"] = out.detach()
    
    # Register hook
    if hasattr(target_model, "model"):
        target_model.model.layers[hook_layer_idx].register_forward_hook(hook_fn)
    else:
        target_model.transformer.h[hook_layer_idx].register_forward_hook(hook_fn)
    
    print(f"  Hooked layer {hook_layer_idx} (N - {layer_offset})")
    
    # Initialize DART head
    dart_head = DARTHead(
        hidden_size=hidden_size,
        head_hidden_size=head_hidden,
        vocab_size=vocab_size,
        num_draft_positions=K,
    ).to(device).half()
    
    # Count parameters
    num_params = sum(p.numel() for p in dart_head.parameters())
    print(f"DART head parameters: {num_params:,}")
    
    # Prepare dataset
    dataset = prepare_dataset(tokenizer, dataset_name, max_samples, K=K)
    dataloader = DataLoader(
        dataset, 
        batch_size=batch_size, 
        shuffle=True,
        collate_fn=collate_fn,
    )
    
    # Optimizer
    optimizer = torch.optim.AdamW(
        dart_head.parameters(),
        lr=learning_rate,
        weight_decay=0.01,
    )
    
    # Learning rate scheduler
    total_steps = len(dataloader) * epochs
    warmup_steps = min(500, total_steps // 10)
    
    def lr_lambda(step):
        if step < warmup_steps:
            return step / warmup_steps
        return max(0.1, 1.0 - (step - warmup_steps) / (total_steps - warmup_steps))
    
    scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, lr_lambda)
    
    # Training stats
    best_loss = float("inf")
    total_tokens = 0
    start_time = time.time()
    
    print(f"\nStarting training:")
    print(f"  Epochs: {epochs}")
    print(f"  Batch size: {batch_size}")
    print(f"  Total steps: {total_steps}")
    print(f"  Warmup steps: {warmup_steps}")
    
    # Training loop
    global_step = 0
    
    for epoch in range(epochs):
        dart_head.train()
        epoch_loss = 0.0
        epoch_steps = 0
        
        for batch_idx, batch in enumerate(dataloader):
            input_ids = batch["input_ids"].to(device)
            B, seq_len = input_ids.shape
            
            # Split: prefix (input) and targets (K tokens to predict)
            prefix_ids = input_ids[:, :-K]
            target_ids = input_ids[:, -K:]
            
            # Get hidden states from target model
            with torch.no_grad():
                _ = target_model(prefix_ids)
            hidden_states = captured_hidden["hs"].half()
            
            # Forward through DART head
            draft_logits = dart_head(hidden_states)  # [B, K, vocab]
            
            # Cross-entropy loss
            ce_loss = F.cross_entropy(
                draft_logits.view(-1, vocab_size),
                target_ids.view(-1),
            )
            
            # Distillation loss (optional)
            if use_distillation:
                with torch.no_grad():
                    # Get target model logits for the K positions
                    full_logits = target_model(input_ids).logits
                    teacher_logits = full_logits[:, -(K+1):-1, :]  # [B, K, vocab]
                
                # KL divergence
                student_log_probs = F.log_softmax(draft_logits / distillation_temp, dim=-1)
                teacher_probs = F.softmax(teacher_logits / distillation_temp, dim=-1)
                kl_loss = F.kl_div(
                    student_log_probs.view(-1, vocab_size),
                    teacher_probs.view(-1, vocab_size),
                    reduction="batchmean",
                ) * (distillation_temp ** 2)
                
                loss = distillation_alpha * kl_loss + (1 - distillation_alpha) * ce_loss
            else:
                loss = ce_loss
            
            # Backward
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(dart_head.parameters(), 1.0)
            optimizer.step()
            scheduler.step()
            
            # Stats
            epoch_loss += loss.item()
            epoch_steps += 1
            global_step += 1
            total_tokens += B * K
            
            # Logging
            if global_step % 100 == 0:
                avg_loss = epoch_loss / epoch_steps
                elapsed = time.time() - start_time
                tps = total_tokens / elapsed
                lr = scheduler.get_last_lr()[0]
                
                print(f"  Step {global_step}/{total_steps} | "
                      f"Loss: {loss.item():.4f} | "
                      f"Avg: {avg_loss:.4f} | "
                      f"LR: {lr:.2e} | "
                      f"TPS: {tps:.0f}")
            
            # Checkpoint
            if global_step % checkpoint_every == 0:
                ckpt_path = f"{output_path}.step{global_step}"
                torch.save(dart_head.state_dict(), ckpt_path)
                print(f"  Saved checkpoint: {ckpt_path}")
        
        # Epoch summary
        avg_loss = epoch_loss / epoch_steps
        print(f"\nEpoch {epoch + 1}/{epochs} complete | Avg loss: {avg_loss:.4f}")
        
        if avg_loss < best_loss:
            best_loss = avg_loss
            torch.save(dart_head.state_dict(), output_path)
            print(f"  Saved best model: {output_path}")
    
    # Final summary
    elapsed = time.time() - start_time
    print(f"\n{'=' * 60}")
    print(f"Training complete!")
    print(f"  Total time: {elapsed:.1f}s ({elapsed/60:.1f}m)")
    print(f"  Total tokens: {total_tokens:,}")
    print(f"  Best loss: {best_loss:.4f}")
    print(f"  Model saved: {output_path}")
    print(f"{'=' * 60}")
    
    return dart_head


# =============================================================================
# Weight Export
# =============================================================================

def export_to_binary(
    checkpoint_path: str,
    output_path: str,
    hidden_size: int,
    vocab_size: int,
    K: int,
    head_hidden: int,
):
    """
    Export trained weights to binary format for Mojo/Zig inference.
    """
    
    print(f"Loading checkpoint: {checkpoint_path}")
    state_dict = torch.load(checkpoint_path, map_location="cpu")
    
    # Calculate sizes
    ffn_dim = head_hidden * 2
    
    print(f"Exporting to: {output_path}")
    
    with open(output_path, "wb") as f:
        # Header (64 bytes)
        f.write(b"DART")  # Magic (4)
        f.write(struct.pack("<I", 1))  # Version (4)
        f.write(struct.pack("<I", hidden_size))  # (4)
        f.write(struct.pack("<I", vocab_size))  # (4)
        f.write(struct.pack("<I", K))  # (4)
        f.write(struct.pack("<I", head_hidden))  # (4)
        f.write(struct.pack("<I", ffn_dim))  # (4)
        f.write(b"\x00" * 36)  # Padding to 64 bytes
        
        scales = []
        
        # Quantize linear layers to INT8
        linear_names = [
            ("input_proj", "weight"),
            ("attention.in_proj_weight", None),  # Combined QKV
            ("attention.out_proj", "weight"),
            ("ffn.0", "weight"),  # FFN up
            ("ffn.2", "weight"),  # FFN down
            ("lm_head", "weight"),
        ]
        
        for name, suffix in linear_names:
            key = f"{name}.{suffix}" if suffix else name
            if key not in state_dict:
                # Try alternate names
                key = name
            
            if key in state_dict:
                weight = state_dict[key].float()
                scale = weight.abs().max() / 127.0
                weight_int8 = (weight / scale).round().clamp(-128, 127).to(torch.int8)
                f.write(weight_int8.numpy().tobytes())
                scales.append(scale.item())
                print(f"  {key}: {weight.shape} -> INT8, scale={scale:.6f}")
            else:
                print(f"  WARNING: {key} not found in state_dict")
        
        # FP16 weights
        fp16_keys = [
            "mask_tokens",
            "pre_norm.weight",
            "pre_norm.bias",
            "post_norm.weight",
            "post_norm.bias",
        ]
        
        for key in fp16_keys:
            if key in state_dict:
                weight = state_dict[key].half()
                f.write(weight.numpy().tobytes())
                print(f"  {key}: {weight.shape} -> FP16")
        
        # Scales
        for scale in scales:
            f.write(struct.pack("<f", scale))
        
    print(f"Export complete: {output_path}")
    print(f"  File size: {os.path.getsize(output_path):,} bytes")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="Train DART head for speculative decoding")
    
    parser.add_argument("--model", type=str, default="meta-llama/Llama-3.1-8B-Instruct",
                       help="Target model name")
    parser.add_argument("--dataset", type=str, default="lmsys/lmsys-chat-1m",
                       help="Training dataset")
    parser.add_argument("--output", type=str, default="dart_head.pt",
                       help="Output path for trained weights")
    parser.add_argument("--epochs", type=int, default=1,
                       help="Number of training epochs")
    parser.add_argument("--batch-size", type=int, default=4,
                       help="Training batch size")
    parser.add_argument("--lr", type=float, default=5e-4,
                       help="Learning rate")
    parser.add_argument("--max-samples", type=int, default=50000,
                       help="Maximum training samples")
    parser.add_argument("--K", type=int, default=4,
                       help="Number of draft positions")
    parser.add_argument("--head-hidden", type=int, default=512,
                       help="DART head hidden dimension")
    parser.add_argument("--layer-offset", type=int, default=4,
                       help="Extract hidden states from layer N - offset")
    parser.add_argument("--no-distillation", action="store_true",
                       help="Disable knowledge distillation")
    parser.add_argument("--export-binary", type=str, default=None,
                       help="Export to binary format after training")
    
    args = parser.parse_args()
    
    # Train
    dart_head = train(
        model_name=args.model,
        output_path=args.output,
        dataset_name=args.dataset,
        epochs=args.epochs,
        batch_size=args.batch_size,
        learning_rate=args.lr,
        max_samples=args.max_samples,
        K=args.K,
        head_hidden=args.head_hidden,
        layer_offset=args.layer_offset,
        use_distillation=not args.no_distillation,
    )
    
    # Export to binary if requested
    if args.export_binary:
        # Get model config
        from transformers import AutoConfig
        config = AutoConfig.from_pretrained(args.model)
        
        export_to_binary(
            checkpoint_path=args.output,
            output_path=args.export_binary,
            hidden_size=config.hidden_size,
            vocab_size=config.vocab_size,
            K=args.K,
            head_hidden=args.head_hidden,
        )


if __name__ == "__main__":
    main()