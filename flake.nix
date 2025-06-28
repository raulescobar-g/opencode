{
  description = "OpenCode development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Version from git or default
        version = "0.1.157";
      in
      {
        # Build packages
        packages = {
          # Go TUI binary (intermediate build)
          opencode-tui = pkgs.buildGoModule rec {
            pname = "opencode-tui";
            inherit version;
            
            src = ./packages/tui;
            
            vendorHash = "sha256-jUxBlBP8eKyDXVvYIZhcrSMfUvGb8/mTPZiPxlCfwLs=";
            
            subPackages = [ "cmd/opencode" ];
            
            ldflags = [
              "-s"
              "-w" 
              "-X main.Version=${version}"
            ];
            
            meta = with pkgs.lib; {
              description = "OpenCode TUI component";
              homepage = "https://github.com/sst/opencode";
              license = licenses.mit;
              maintainers = [ ];
              platforms = platforms.unix;
            };
          };
          
          # Main OpenCode package with bun wrapper
          opencode = pkgs.buildNpmPackage rec {
            pname = "opencode";
            inherit version;
            
            src = ./packages/opencode;
            
            # Lock file hash - will need to be updated on first build
            npmDepsHash = "sha256-DtgGECVz9mtrsK+/psKSrZsBMdff+sZs5hlCi/xCCHM=";
            
            # Fix npm dependency issues
            makeCacheWritable = true;
            npmFlags = [ "--legacy-peer-deps" ];
            
            nativeBuildInputs = with pkgs; [
              bun
            ];
            
            buildInputs = with pkgs; [
              fzf        # Runtime dependency from AUR
              ripgrep    # Runtime dependency from AUR  
            ];
            
            # Copy the vendored package-lock.json as suggested by the hint
            postPatch = ''
              # Copy the pre-generated package-lock.json
              cp ${./packages/opencode/package-lock.json} package-lock.json
              
              # Substitute catalog references with actual versions
              substituteInPlace package.json \
                --replace '"typescript": "catalog:"' '"typescript": "5.8.2"' \
                --replace '"ai": "catalog:"' '"ai": "4.3.16"' \
                --replace '"zod": "catalog:"' '"zod": "3.24.2"'
              
              # Patch the models macro to avoid network access during build
              cat > src/provider/models-macro.ts << 'EOF'
export async function data() {
  // Fallback data for build-time - actual data will be fetched at runtime
  return JSON.stringify({});
}
EOF
            '';
            
            # Copy the tui source for building
            preBuild = ''
              # Copy the pre-built TUI binary instead of building from source
              cp ${self.packages.${system}.opencode-tui}/bin/opencode tui-binary
            '';
            
            # Don't run npm scripts during dependency installation
            dontNpmBuild = true;
            
            buildPhase = ''
              runHook preBuild
              
              # Build the bun wrapper with embedded TUI binary (using pre-built binary)
              bun build --define OPENCODE_VERSION="'${version}'" --compile --minify \
                --target=bun-linux-x64 --outfile=opencode-wrapper ./src/index.ts ./tui-binary
              
              runHook postBuild
            '';
            
            installPhase = ''
              runHook preInstall
              
              mkdir -p $out/bin
              cp opencode-wrapper $out/bin/opencode
              chmod +x $out/bin/opencode
              
              runHook postInstall
            '';
            
            meta = with pkgs.lib; {
              description = "The AI coding agent built for the terminal with full Node.js wrapper";
              homepage = "https://github.com/sst/opencode";
              license = licenses.mit;
              maintainers = [ ];
              platforms = platforms.unix;
              mainProgram = "opencode";
            };
          };
          
          # Development build (for local development)
          opencode-dev = pkgs.stdenv.mkDerivation rec {
            pname = "opencode-dev";
            inherit version;
            
            src = ./.;
            
            nativeBuildInputs = with pkgs; [
              bun
              nodejs_24
            ];
            
            # Don't try to fetch dependencies in build
            dontBuild = true;
            dontConfigure = true;
            
            installPhase = ''
              mkdir -p $out/bin $out/share/opencode
              
              # Copy the source for development
              cp -r . $out/share/opencode/src
              
              # Create a development wrapper script
              cat > $out/bin/opencode-dev << 'EOF'
#!/bin/sh
cd "$out/share/opencode/src"
if [ ! -d node_modules ]; then
  echo "Installing dependencies..."
  bun install
fi
exec bun run packages/opencode/src/index.ts "$@"
EOF
              chmod +x $out/bin/opencode-dev
            '';
            
            meta = with pkgs.lib; {
              description = "OpenCode development version with Node.js wrapper";
              homepage = "https://github.com/sst/opencode";
              license = licenses.mit;
              maintainers = [ ];
              platforms = platforms.unix;
            };
          };
          
          # Default package points to the simple Go package (best for nixpkgs)
          default = self.packages.${system}.opencode;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Core runtime requirements
            bun              # JavaScript runtime and package manager (Bun 1.x)
            go_1_24          # Go compiler 1.24.x as specified in README
            nodejs_24        # Node.js for TypeScript/web development
          ];

          shellHook = ''
            # Welcome message
            echo "🚀 OpenCode development environment loaded!"
            echo ""
            echo "Available packages:"
            echo "  • nix build                   - Simple Go binary (recommended for nixpkgs)"
            echo "  • nix build .#opencode   - Full wrapper with bun (complex)"
            echo "  • nix build .#opencode-dev    - Development version"
            echo ""
            echo "Getting started:"
            echo "  1. Run 'bun install' to install dependencies"
            echo "  2. Run 'bun run packages/opencode/src/index.ts' to start opencode"
            echo "  3. Run 'nix build' to build the full package with bun wrapper"
            echo "  4. Run 'nix build .#opencode-tui' to build just the Go TUI"
            echo ""
          '';

        };
        
        # Apps for easy running
        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.opencode}/bin/opencode";
          };
          
          opencode = {
            type = "app"; 
            program = "${self.packages.${system}.opencode}/bin/opencode";
          };
        };
      });
} 